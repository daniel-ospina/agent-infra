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
    # ── the stale-by-base re-run: the ONE mutation this step may make ─────────────────────────────
    # `gh api -X POST repos/<o>/<r>/actions/runs/<id>/rerun-failed-jobs`. Logged to its OWN file so an
    # arm can assert what was RE-RUN, and that nothing was re-run when the answer is "no".
    case "$*" in
      *"-X POST"*"rerun-failed-jobs"*)
        printf '%s\n' "$*" >>"${STUB_CALLS}.rerun"
        if [ -e "$FX/rerun_fail" ]; then printf 'gh: Forbidden (HTTP 403)\n' >&2; exit 1; fi
        printf '{}\n'; exit 0 ;;
    esac
    path="${2:-}"
    case "$path" in
      rate_limit) printf '%s\n' "$(cat "$FX/rate.json" 2>/dev/null || printf '{"resources":{"core":{"remaining":1000}}}')" ;;
      graphql)
        case "$*" in
          *defaultBranchRef*) cat "$FX/base.json" 2>/dev/null || printf '{"data":{"repository":{"defaultBranchRef":{"target":{"committedDate":"2026-10-23T12:51:03Z"}}}}}\n' ;;
          *pullRequests*)     cat "$FX/rollup.json" 2>/dev/null || printf '{"data":{"repository":{"pullRequests":{"nodes":[]}}}}\n' ;;
          *) printf '{"data":{}}\n' ;;
        esac ;;
    esac
    pn="$(printf '%s' "$path" | sed -n 's#.*/pulls/\([0-9][0-9]*\).*#\1#p')"
    case "$path" in
      rate_limit|graphql) : ;;
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
  : >"$STUB_CALLS.rerun"
  printf '{"resources":{"core":{"remaining":1000}}}\n' >"$FX/rate.json"
  printf '{"data":{"repository":{"defaultBranchRef":{"target":{"committedDate":"2026-10-23T12:51:03Z"}}}}}\n' >"$FX/base.json"
}

# base_tip <iso8601 Z> — the clock the staleness rule measures against
base_tip() { printf '{"data":{"repository":{"defaultBranchRef":{"target":{"committedDate":"%s"}}}}}\n' "$1" >"$FX/base.json"; }

# surface <pr> <name|conclusion|startedAt|run_id|check_run_id> ... — the check surface for one PR.
# Several attempts of ONE name can be listed: the newest by databaseId is the one that counts, which
# is what a re-run produces (a re-run ADDS a check run, it never replaces one).
surface() {
  local pr="$1"; shift
  python3 - "$FX/rollup.json" "$pr" "$@" <<'PY'
import json, sys
p, pr = sys.argv[1], int(sys.argv[2])
checks = []
for spec in sys.argv[3:]:
    name, concl, started, run, cid = spec.split("|")
    checks.append({"__typename": "CheckRun", "databaseId": int(cid), "name": name,
                   "status": "COMPLETED", "conclusion": concl, "startedAt": started,
                   "checkSuite": {"app": {"slug": "github-actions"},
                                  "workflowRun": {"databaseId": int(run), "workflow": {"name": "CI"}}}})
try:
    d = json.load(open(p))
except Exception:
    d = {"data": {"repository": {"pullRequests": {"nodes": []}}}}
nodes = d["data"]["repository"]["pullRequests"]["nodes"]
nodes = [n for n in nodes if n["number"] != pr]
nodes.append({"number": pr, "commits": {"nodes": [{"commit": {"statusCheckRollup":
              {"contexts": {"nodes": checks}}}}]}})
# ⛔ RE-ATTACH. `nodes` is a NEW list; appending to it does nothing to `d` until it is put back.
# (Found by the suite: the fixture was written, and every arm read an EMPTY surface.)
d["data"]["repository"]["pullRequests"]["nodes"] = nodes
json.dump(d, open(p, "w"))
PY
}

rerun_calls() { cat "$STUB_CALLS.rerun" 2>/dev/null | awk 'NF{print}' | tr '\n' ' '; }
# ⛔ COUNT THE FILE, NEVER THE JOINED STRING. `rerun_calls` collapses newlines to spaces, so
# `grep -c` on IT always returns 1 and the two "exactly ONE POST" arms could not fail (measured by a
# reviewer: the per-run dedupe removed, two POSTs in the log, the arm still said 1).
post_count() { grep -c 'rerun-failed-jobs' "$STUB_CALLS.rerun" 2>/dev/null || true; }
state_file() { printf '%s/state/stale-rerun-stub-repo.tsv' "$O"; }

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
if grep -qE '^\[lander\] #102 .*(skipped|FAIL)' <<<"$OUT"; then
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
if grep -qE '^\[lander\] #103 .*waiting' <<<"$OUT"; then
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
n="$(grep -c 'CI queue depth' <<<"$OUT")"
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
if grep -qE '^\[lander\] #105 .*waiting' <<<"$OUT"; then
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
if grep -qE '^\[lander\] #108 .*FAILED check' <<<"$OUT"; then
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

# ══ CASES 11-18 — STALE-BY-BASE RE-RUN ═══════════════════════════════════════════════════════════
# The rule: a RED check whose `started_at` PREDATES the current base tip's committer date measured a
# tree that no longer exists → RE-MEASURE it. BOTH directions are asserted, because a one-directional
# suite passes for a tool that re-runs EVERYTHING (a bypass, not a measurement).
BASE_ISO=2026-10-23T12:51:03Z          # the base tip every arm below measures against

say_case "case 11 — (i) a RED check started BEFORE the base tip IS selected and re-run (run-scoped)"
new_case
base_tip "$BASE_ISO"
seed 111 MERGEABLE CLEAN false aaaa111122223333444455556666777788889999
checks 111 sigpipe-grep:failure test:success
surface 111 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|5001|1001" "test|SUCCESS|2026-10-23T01:05:00Z|5001|1002"
run_lander
has "$(rerun_calls)" "actions/runs/5001/rerun-failed-jobs" \
  && ok "STALE: the run carrying the stale red was re-run (rerun calls: $(rerun_calls))" \
  || bad "STALE: a stale red was NOT re-run (rerun calls: '$(rerun_calls)')"
has "$OUT" "#111 sigpipe-grep RE-RUN (run 5001, check 1001 started 2026-10-23T01:00:00Z" \
  && ok "STALE: the report names the check id, its start time and the base tip it was measured against" \
  || bad "STALE: the re-run is not reported with its evidence ($(printf '%s\n' "$OUT" | grep 'stale-rerun' | head -2))"
grep -q "^R" "$(state_file)" 2>/dev/null \
  && ok "STALE: the re-run was recorded in the state file (so its outcome is read on a later pass)" \
  || bad "STALE: nothing was recorded in $(state_file)"
n_posts="$(post_count)"
[ "$n_posts" = "1" ] && ok "STALE: exactly ONE POST for the run — the green sibling was not re-run by name" \
                     || bad "STALE: expected exactly 1 POST, got $n_posts ('$(rerun_calls)')"

say_case "case 12 — (ii) a RED check started AFTER the base tip is NOT selected (this tree is current)"
new_case
base_tip "$BASE_ISO"
seed 112 MERGEABLE CLEAN false bbbb111122223333444455556666777788889999
checks 112 sigpipe-grep:failure
surface 112 "sigpipe-grep|FAILURE|2026-10-23T13:30:00Z|5002|1003"
printf '1\n' >"$FX/checks_rc-112"
run_lander
[ -z "$(rerun_calls)" ] && ok "NOT-STALE: a red started AFTER the base tip was NOT re-run" \
                         || bad "NOT-STALE: a red that measured the CURRENT tree was re-run (calls: '$(rerun_calls)')"
has "$OUT" "stale-by-base=0" && ok "NOT-STALE: the step counts it as not-stale, and says so" \
                              || bad "NOT-STALE: the report does not say stale-by-base=0 ($(printf '%s\n' "$OUT" | grep 'stale-rerun: stale-by-base'))"
has "$OUT" "#112 skipped: 1 FAILED check(s): sigpipe-grep (failure)" \
  && ok "NOT-STALE: the PR is still reported RED by the drain loop — 'not re-run' is not 'not red'" \
  || bad "NOT-STALE: the PR stopped being reported red ($OUT)"

say_case "case 13 — (iii) a non-base failure comes back STILL-RED: reported, never dropped or greened"
new_case
base_tip "$BASE_ISO"
seed 113 MERGEABLE CLEAN false cccc111122223333444455556666777788889999
checks 113 sigpipe-grep:failure
# The re-run produced a NEW attempt (id 2001, started AFTER the tip) and it is STILL a failure:
# the red belongs to the branch. The tool must say so, and must NOT re-run it a second time.
surface 113 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|5003|1003" \
            "sigpipe-grep|FAILURE|2026-10-23T13:40:00Z|5003|2001"
printf 'R\t%s\t113\t5003\tsigpipe-grep\t1003\t2026-10-23T01:00:00Z\n' "$(date -u +%s)" >"$(state_file)"
run_lander
has "$OUT" "#113 sigpipe-grep is STILL-RED (check 2001, replacing 1003)" \
  && ok "STILL-RED: reported as still-red against the NEW attempt id (newest by id, not a rollup state)" \
  || bad "STILL-RED: a non-base failure was not reported as still-red ($(printf '%s\n' "$OUT" | grep 'stale-rerun' | head -3))"
case "$OUT" in *"#113 sigpipe-grep is now SUCCESS"*) bad "STILL-RED: a still-red check was reported as SUCCESS" ;; *) ok "STILL-RED: not reported as success" ;; esac
[ -z "$(rerun_calls)" ] && ok "STILL-RED: the still-red check was NOT re-run a second time" \
                         || bad "STILL-RED: an already-re-run still-red check was re-run again ('$(rerun_calls)')"
grep -q '^O.*still-red' "$(state_file)" 2>/dev/null && ok "STILL-RED: the outcome is written to the state as still-red" \
                                                 || bad "STILL-RED: the outcome was not recorded ($(cat "$(state_file)" 2>/dev/null | tr '\n' ' '))"

say_case "case 14 — (iv) the state file stops a re-run loop (same run, no new attempt yet)"
new_case
base_tip "$BASE_ISO"
seed 114 MERGEABLE CLEAN false dddd111122223333444455556666777788889999
checks 114 sigpipe-grep:failure
surface 114 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|5004|1004"    # SAME id still newest: no new attempt
printf 'R\t%s\t114\t5004\tsigpipe-grep\t1004\t2026-10-23T01:00:00Z\n' "$(date -u +%s)" >"$(state_file)"
run_lander
[ -z "$(rerun_calls)" ] && ok "LOOP: the same run was NOT re-run twice inside the window" \
                         || bad "LOOP: the state file did not prevent a re-run loop ('$(rerun_calls)')"
has "$OUT" "#114 sigpipe-grep skipped — run 5004 was already re-run inside the" \
  && ok "LOOP: the skip is NAMED (a silent skip would hide a red)" \
  || bad "LOOP: the skip is not reported ($(printf '%s\n' "$OUT" | grep 'stale-rerun' | head -2))"

say_case "case 15 — a re-run that resolved the red is reported SUCCESS against the newest attempt"
new_case
base_tip "$BASE_ISO"
seed 115 MERGEABLE CLEAN false eeee111122223333444455556666777788889999
checks 115 sigpipe-grep:success
surface 115 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|5005|1005" \
            "sigpipe-grep|SUCCESS|2026-10-23T13:41:00Z|5005|2005"
printf 'R\t%s\t115\t5005\tsigpipe-grep\t1005\t2026-10-23T01:00:00Z\n' "$(date -u +%s)" >"$(state_file)"
run_lander
has "$OUT" "#115 sigpipe-grep is now SUCCESS (check 2005, replacing 1005)" \
  && ok "SUCCESS: reported from the NEWEST attempt by id" \
  || bad "SUCCESS: a resolved re-run was not reported as success ($(printf '%s\n' "$OUT" | grep 'stale-rerun' | head -3))"

say_case "case 16 — an unreadable base tip re-runs NOTHING (fail-closed, and named)"
new_case
printf '{"data":{"repository":{"defaultBranchRef":{"target":null}}}}\n' >"$FX/base.json"
seed 116 MERGEABLE CLEAN false ffff111122223333444455556666777788889999
checks 116 sigpipe-grep:failure
surface 116 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|5006|1006"
run_lander
[ -z "$(rerun_calls)" ] && ok "NO-CLOCK: nothing re-run without a base tip to measure against" \
                         || bad "NO-CLOCK: a re-run was issued with no base tip ('$(rerun_calls)')"
has "$OUT" "the base tip could not be read over GraphQL" \
  && ok "NO-CLOCK: the refusal is named, not silent" || bad "NO-CLOCK: the refusal is silent ($OUT)"

say_case "case 17 — pipeline-compliance is EXCLUDED by name (a different defect, a different owner)"
new_case
base_tip "$BASE_ISO"
seed 117 MERGEABLE CLEAN false aaaa2222333344445555666677778888999900001
checks 117 pipeline-compliance:failure
surface 117 "pipeline-compliance|FAILURE|2026-10-23T01:00:00Z|5007|1007"
run_lander
[ -z "$(rerun_calls)" ] && ok "EXCLUDED: the required check was NOT swept into this mechanism" \
                         || bad "EXCLUDED: pipeline-compliance was re-run by the stale-by-base step ('$(rerun_calls)')"
has "$OUT" "excluded-by-name=1" && ok "EXCLUDED: the exclusion is COUNTED, so it cannot hide a red" \
                                    || bad "EXCLUDED: the exclusion is invisible ($(printf '%s\n' "$OUT" | grep 'stale-rerun: stale-by-base'))"
has "$OUT" "is #2467's class" && ok "EXCLUDED: the owner of the other mechanism is named" \
                               || bad "EXCLUDED: the report does not name the other mechanism ($OUT)"

say_case "case 18 — the REST budget decides N: with no headroom beyond the reserve, NOTHING is re-run"
new_case
base_tip "$BASE_ISO"
printf '{"resources":{"core":{"remaining":504}}}\n' >"$FX/rate.json"   # 504 - 500 reserve = 4 -> 0 runs at 5 pts
seed 118 MERGEABLE CLEAN false aaaa3333444455556666777788889999000011112
checks 118 sigpipe-grep:failure
surface 118 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|5008|1008"
run_lander
[ -z "$(rerun_calls)" ] && ok "BUDGET: N=0 means no mutation is spent when the bucket has no headroom" \
                         || bad "BUDGET: a re-run was spent with no budget ('$(rerun_calls)')"
has "$OUT" "budget N=0 run(s) (REST core 504 left" \
  && ok "BUDGET: the derived N and the budget it came from are PRINTED" \
  || bad "BUDGET: the budget line is wrong/missing ($(printf '%s\n' "$OUT" | grep 'stale-rerun: stale-by-base'))"
has "$OUT" "stale-by-base=1" && ok "BUDGET: the stale check is still COUNTED even when it cannot be re-run" \
                               || bad "BUDGET: the stale check vanished from the count ($OUT)"
say_case "case 19 — a REFUSED re-run (403: workflow already running) is named, recorded, and not retried"
new_case
base_tip "$BASE_ISO"
: >"$FX/rerun_fail"                       # the API refuses every re-run this pass
seed 119 MERGEABLE CLEAN false aaaa4444555566667777888899990000111122223
checks 119 sigpipe-grep:failure
surface 119 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|5009|1009"
run_lander
has "$OUT" "#119 sigpipe-grep re-run REFUSED by the API (run 5009)" \
  && ok "REFUSED: the refusal is reported, with what the API said" \
  || bad "REFUSED: a refused re-run is silent ($(printf '%s\n' "$OUT" | grep 'stale-rerun' | head -2))"
has "$OUT" "NOT treated as green" && ok "REFUSED: it is explicitly NOT read as a pass" \
                                   || bad "REFUSED: the report does not say the red still stands ($OUT)"
grep -q '^D' "$(state_file)" 2>/dev/null && ok "REFUSED: recorded as a deferral (D), not as an outcome" \
                                          || bad "REFUSED: the refusal was not recorded ($(cat "$(state_file)" 2>/dev/null | tr '\n' ' '))"
grep -q '^O' "$(state_file)" 2>/dev/null && bad "REFUSED: a refused re-run was resolved into an outcome" \
                                         || ok "REFUSED: it was NOT resolved into a success/still-red outcome"
# Second pass, same run, API now healthy: the DEFERRAL from above must stop a second POST.
: >"$STUB_CALLS.rerun"; rm -f "$FX/rerun_fail"
run_lander
[ -z "$(rerun_calls)" ] && ok "REFUSED: the next pass does NOT pay another POST for the same run inside the window" \
                         || bad "REFUSED: a deferred run was retried immediately ('$(rerun_calls)')"
has "$OUT" "#119 sigpipe-grep skipped — run 5009 was already re-run inside the" \
  && ok "REFUSED: the deferral is reported as a windowed skip, so the red is still visible" \
  || bad "REFUSED: the deferral is silent on the next pass ($(printf '%s\n' "$OUT" | grep 'stale-rerun' | head -2))"
say_case "case 20 — the BOUNDARY: started_at EQUAL to the base tip is NOT stale; one second before IS"
# The rule is `started_at < base tip`. A `<` vs `<=` slip ships a re-run of a check that measured the
# CURRENT tree, so both sides of the boundary are pinned here (the reviewer measured that flipping the
# comparison to `<=` left the whole suite green — it was uncovered).
new_case
base_tip "$BASE_ISO"
seed 120 MERGEABLE CLEAN false aaaa5555666677778888999900001111222233334
checks 120 sigpipe-grep:failure
surface 120 "sigpipe-grep|FAILURE|$BASE_ISO|6001|1101"          # EXACTLY the tip
run_lander
[ -z "$(rerun_calls)" ] && ok "BOUNDARY: started_at EQUAL to the base tip is NOT stale (no re-run)" \
                         || bad "BOUNDARY: a check started AT the tip was re-run ('$(rerun_calls)')"
has "$OUT" "stale-by-base=0" && ok "BOUNDARY: and it is counted as not-stale" \
                              || bad "BOUNDARY: the equal case is miscounted ($(printf '%s\n' "$OUT" | grep 'stale-rerun: stale-by-base'))"

new_case
base_tip "$BASE_ISO"
seed 121 MERGEABLE CLEAN false aaaa6666777788889999000011112222333344445
checks 121 sigpipe-grep:failure
surface 121 "sigpipe-grep|FAILURE|2026-10-23T12:51:02Z|6002|1102"   # exactly one second BEFORE the tip
run_lander
has "$(rerun_calls)" "actions/runs/6002/rerun-failed-jobs" \
  && ok "BOUNDARY: one second before the tip IS stale and is re-run" \
  || bad "BOUNDARY: a check started 1s before the tip was not re-run ('$(rerun_calls)')"

say_case "case 21 — a re-run's TWO attempts are co-resident: the drain must judge the NEWEST, not count both"
# The re-run ADDS a check-run. A drain that counts every row reports the PR red forever after a
# re-run came back GREEN — i.e. the value this step produces would be invisible to the only consumer
# that decides a merge. This fixture is exactly what a successful re-run leaves on the head.
new_case
base_tip "$BASE_ISO"
seed 122 MERGEABLE CLEAN false aaaa7777888899990000111122223333444455556
python3 - "$FX/checks-122.json" <<'PY'
import json, sys
json.dump([
    {"name": "sigpipe-grep", "state": "failure", "workflow": "CI", "startedAt": "2026-10-23T01:26:15Z"},
    {"name": "sigpipe-grep", "state": "success", "workflow": "CI", "startedAt": "2026-10-23T13:58:23Z"},
], open(sys.argv[1], "w"))
PY
run_lander
has "$(merged_nums)" "122" && ok "CO-RESIDENT: the superseded failure does not block the merge — the newest attempt is the verdict" \
                           || bad "CO-RESIDENT: a PR whose re-run went green was NOT merged (merge calls: '$(merged_nums)')"
if grep -q 'FAILED check' <<<"$OUT"; then
  bad "CO-RESIDENT: the superseded failure is still counted ($(printf '%s\n' "$OUT" | grep 'FAILED check'))"
else ok "CO-RESIDENT: the superseded failure is not counted as a failure"; fi
say_case "case 22 — TWO stale checks in ONE run get ONE POST (the cap counts runs; the POSTs must too)"
new_case
base_tip "$BASE_ISO"
seed 123 MERGEABLE CLEAN false aaaa8888999900001111222233334444555566667
checks 123 sigpipe-grep:failure bash-suites:failure
surface 123 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|6010|1110" \
            "bash-suites|FAILURE|2026-10-23T01:00:01Z|6010|1111"
run_lander
n_posts="$(post_count)"
[ "$n_posts" = "1" ] && ok "RUN-SCOPE: two stale checks sharing run 6010 produced exactly ONE POST" \
                     || bad "RUN-SCOPE: expected 1 POST for run 6010, got $n_posts ('$(rerun_calls)')"
has "$OUT" "#123 bash-suites is re-run by the SAME run 6010 already POSTed in this pass (check 1111)" \
  && ok "RUN-SCOPE: the second check is still REPORTED and RECORDED (re-run by the run's POST, not dropped)" \
  || bad "RUN-SCOPE: the second stale check vanished from the report ($(printf '%s\n' "$OUT" | grep 'stale-rerun: #123'))"
[ "$(grep -c '^R' "$(state_file)")" = "2" ] && ok "RUN-SCOPE: both checks got their own R record, so BOTH outcomes are read later" \
                                           || bad "RUN-SCOPE: expected 2 R records (one per check), got $(grep -c '^R' "$(state_file)")"
say_case "case 23 — TWO PASSES: the R record a pass WRITES is the one the next pass READS (writer->reader)"
# ⛔ THIS IS THE ARM THAT WAS MISSING. Every other arm seeds the state by hand, so an off-by-one field
# mapping in the WRITER (app and workflow in the wrong slots) made the reader miss its key and NO
# outcome was ever produced — while the whole suite stayed green. Pass 1 runs for real; pass 2 must
# read pass 1's own record and report the new attempt.
new_case
base_tip "$BASE_ISO"
seed 124 MERGEABLE CLEAN false aaaa9999000011112222333344445555666677778
checks 124 sigpipe-grep:failure
surface 124 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|6020|3001"
run_lander
has "$(rerun_calls)" "actions/runs/6020/rerun-failed-jobs" \
  && ok "2-PASS: pass 1 issued the POST" || bad "2-PASS: pass 1 did not POST ('$(rerun_calls)')"
grep -q '^R' "$(state_file)" 2>/dev/null && ok "2-PASS: pass 1 wrote an R record" \
                                        || bad "2-PASS: pass 1 wrote no R record"
# The re-run produces a NEW attempt with a NEW check-run id and a NEWER startedAt; the old one stays.
surface 124 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|6020|3001" \
            "sigpipe-grep|SUCCESS|2026-10-23T14:30:00Z|6020|4001"
: >"$STUB_CALLS.rerun"
run_lander
has "$OUT" "#124 sigpipe-grep is now SUCCESS (check 4001, replacing 3001)" \
  && ok "2-PASS: pass 2 READ pass 1's record and reported the outcome against the new attempt" \
  || bad "2-PASS: pass 2 produced no outcome from pass 1's record — the writer and the reader disagree ($(printf '%s\n' "$OUT" | grep 'stale-rerun' | head -3))"
grep -q '^O.*success' "$(state_file)" 2>/dev/null && ok "2-PASS: the resolved record was folded into an O row" \
                                                || bad "2-PASS: no O row ($(cat "$(state_file)" 2>/dev/null | tr '\n' ' '))"
grep -q '^R' "$(state_file)" 2>/dev/null && bad "2-PASS: the resolved R row was not consumed (it will be re-reported forever)" \
                                        || ok "2-PASS: the resolved R row was consumed"
[ "$(post_count)" = "0" ] && ok "2-PASS: pass 2 issued no POST (the new attempt measures the tree)" \
                          || bad "2-PASS: pass 2 re-ran a run it had already re-run ('$(rerun_calls)')"
say_case "case 24 — a SAME-SECOND tie must resolve to the RED, in both orders (fail-closed, not list order)"
# `startedAt` has one-second resolution and `max()` returns the FIRST maximal element, so a red and a
# green attempt started in the same second used to resolve by LIST ORDER (measured: [success,failure]
# merged; [failure,success] did not). Covered in both orders so a positional tie-break cannot pass.
# ⛔ NO `set --` HERE. It clobbers the SCRIPT POSITIONAL PARAMETERS, and `--nonvacuity` is read from
# `$1` at the end of this file — so a `set --` inside one case silently turned the non-vacuity mutant
# gate into a no-op that exited 0 (caught by the verification gate: the mutant check never ran).
for order in "success:failure" "failure:success"; do
  new_case
  base_tip "$BASE_ISO"
  seed 125 MERGEABLE CLEAN false bbbb0000111122223333444455556666777788889
  ORDER_FIRST="${order%%:*}"; ORDER_SECOND="${order##*:}"
  python3 - "$FX/checks-125.json" "$ORDER_FIRST" "$ORDER_SECOND" <<'PY'
import json, sys
p, first, second = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump([
    {"name": "sigpipe-grep", "state": first,  "workflow": "CI", "startedAt": "2026-10-23T13:58:23Z"},
    {"name": "sigpipe-grep", "state": second, "workflow": "CI", "startedAt": "2026-10-23T13:58:23Z"},
], open(p, "w"))
PY
  run_lander
  [ -z "$(merged_nums)" ] && ok "TIE ($order): a same-second red is NOT merged away" \
                          || bad "TIE ($order): a same-second red was MERGED (merge calls: '$(merged_nums)')"
  grep -q 'FAILED check' <<<"$OUT" && ok "TIE ($order): and it is still reported as a failing check" \
                                   || bad "TIE ($order): the red is not reported ($OUT)"
done

say_case "case 25 — a run carrying an EXCLUDED check is dropped ENTIRELY (the POST re-runs every failed job in it)"
new_case
base_tip "$BASE_ISO"
seed 126 MERGEABLE CLEAN false cccc0000111122223333444455556666777788889
checks 126 sigpipe-grep:failure pipeline-compliance:failure
# ONE run carries both: the stale sigpipe red and the excluded required check.
surface 126 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|7030|1201" \
            "pipeline-compliance|FAILURE|2026-10-23T01:00:05Z|7030|1202"
run_lander
[ -z "$(rerun_calls)" ] && ok "EXCLUDED-RUN: the shared run was NOT re-run (which would have re-run #2467's check)" \
                         || bad "EXCLUDED-RUN: the run carrying the excluded check WAS re-run ('$(rerun_calls)')"
has "$OUT" "run(s)-dropped=1" && ok "EXCLUDED-RUN: the dropped run is COUNTED" \
                              || bad "EXCLUDED-RUN: the drop is invisible ($(printf '%s\n' "$OUT" | grep 'stale-rerun: stale-by-base'))"

say_case "case 26 — each unreadable surface is a NAMED refusal (the guards the fail-closed claim rests on)"
# 26a: GraphQL errors
new_case
rm -f "$FX/rollup.json"
printf '{"errors":[{"message":"something the API refused"}]}\n' >"$FX/rollup.json"
seed 127 MERGEABLE CLEAN false dddd0000111122223333444455556666777788889
checks 127 sigpipe-grep:success
run_lander
[ -z "$(rerun_calls)" ] && ok "REFUSAL(errors): 0 re-runs on a GraphQL-error surface" \
                         || bad "REFUSAL(errors): re-ran on an errored surface ('$(rerun_calls)')"
has "$OUT" "returned GraphQL errors" && ok "REFUSAL(errors): the reason is NAMED, not 'printed nothing explanatory'" \
                                     || bad "REFUSAL(errors): the reason is not surfaced ($(printf '%s\n' "$OUT" | grep stale-rerun | head -2))"
# 26b: unparseable body
new_case
printf 'not json at all\n' >"$FX/rollup.json"
seed 128 MERGEABLE CLEAN false eeee0000111122223333444455556666777788889
checks 128 sigpipe-grep:success
run_lander
[ -z "$(rerun_calls)" ] && ok "REFUSAL(unparseable): 0 re-runs" || bad "REFUSAL(unparseable): re-ran ('$(rerun_calls)')"
has "$OUT" "could not be parsed" && ok "REFUSAL(unparseable): the reason is NAMED" \
                                  || bad "REFUSAL(unparseable): reason missing ($(printf '%s\n' "$OUT" | grep stale-rerun | head -2))"
# 26c: a TRUNCATED surface (pageInfo.hasNextPage) is refused, not sampled
new_case
printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[{"number":129,"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"pageInfo":{"hasNextPage":true},"nodes":[{"__typename":"CheckRun","databaseId":1301,"name":"sigpipe-grep","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-23T01:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":7040,"workflow":{"name":"CI"}}}}]}}}}]}}]}}}}\n' >"$FX/rollup.json"
seed 129 MERGEABLE CLEAN false ffff0000111122223333444455556666777788889
checks 129 sigpipe-grep:failure
run_lander
[ -z "$(rerun_calls)" ] && ok "REFUSAL(truncated): a truncated check surface re-runs NOTHING" \
                         || bad "REFUSAL(truncated): re-ran from a truncated surface ('$(rerun_calls)')"
has "$OUT" "TRUNCATED" && ok "REFUSAL(truncated): the refusal names truncation" \
                        || bad "REFUSAL(truncated): truncation not named ($(printf '%s\n' "$OUT" | grep stale-rerun | head -2))"
# 26d: the PR LIST truncated
new_case
printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}\n' >"$FX/rollup.json"
seed 130 MERGEABLE CLEAN false aaaa1111000022223333444455556666777788889
checks 130 sigpipe-grep:success
run_lander
[ -z "$(rerun_calls)" ] && ok "REFUSAL(truncated list): 0 re-runs when the PR list is a SAMPLE" \
                         || bad "REFUSAL(truncated list): re-ran from a sampled board ('$(rerun_calls)')"
has "$OUT" "PR list was TRUNCATED" && ok "REFUSAL(truncated list): named" \
                                   || bad "REFUSAL(truncated list): not named ($(printf '%s\n' "$OUT" | grep stale-rerun | head -2))"

say_case "case 27 — the two numeric guards that bound a mutation are pinned"
# 27a: an overflowed CAP must not lift the ceiling
new_case
base_tip "$BASE_ISO"
seed 131 MERGEABLE CLEAN false bbbb1111000022223333444455556666777788889
checks 131 sigpipe-grep:failure
surface 131 "sigpipe-grep|FAILURE|2026-10-23T01:00:00Z|7050|1401"
STALE_RERUN_CAP=999999999999999999999999 run_lander
has "$OUT" "budget N=50 run(s)" && ok "GUARD(cap): an overflowed STALE_RERUN_CAP is clamped to the 50 ceiling" \
                                || bad "GUARD(cap): the ceiling did not hold ($(printf '%s\n' "$OUT" | grep 'stale-rerun: stale-by-base'))"
# 27b: an unusable TMPDIR must SAY SO rather than going silent
new_case
base_tip "$BASE_ISO"
seed 132 MERGEABLE CLEAN false cccc1111000022223333444455556666777788889
checks 132 sigpipe-grep:success
OUT_SO="$(O="$O" TMPDIR=/proc/definitely-not-writable GH_TOKEN=stub-invalid-token bash "$LANDER" --repo stub/repo --max 5 2>&1)"
has "$OUT_SO" "no scratch directory" && ok "GUARD(tmpdir): an unusable TMPDIR produces a LINE, not silence" \
                                     || bad "GUARD(tmpdir): the step went silent ($(printf '%s\n' "$OUT_SO" | grep stale-rerun | head -2))"
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
  if grep -q 'FAIL .*PENDING' <<<"$MOUT"; then
    printf 'ok        — non-vacuity: the PENDING arm is the one that breaks (not an unrelated crash)\n'
  else
    printf 'FAIL      — non-vacuity: the mutant failed, but NOT on the PENDING arm — the arm may be passing for the wrong reason\n'
    grep 'FAIL' <<<"$MOUT" | sed 's/^/    /'
    exit 1
  fi
  printf '\nnon-vacuity: PASS\n'
  exit 0
fi
