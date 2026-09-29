#!/usr/bin/env bash
# tests/atomic-land/run.sh — the atomic land unit: update → verify → record → land (#1367).
#
# The rail: `strict: true` requires an up-to-date head, and the head-bound review
# evidence requires a record at the head sha. Satisfying the first moves the head
# and stales the record, and `main` moves faster than a CI cycle, so the four
# steps performed as separate turns lose the window (tortoise #4764: 48/69 open
# PRs with no valid attestation; the O3 sweep: 22 updated, 17 invalidated, 0
# landed). The rail is
#
#   scripts/atomic-land.sh      update → verify → record → land, as ONE unit
#   scripts/record-review.sh    the record's diff guard + carry-forward (#767)
#   scripts/admin-merge.sh      the land step (never a hand-rolled merge)
#
# What this suite pins:
#  1. THE UNIT IS ORDERED AND ATOMIC: on a BEHIND PR the rail updates, waits for
#     terminal checks, re-records at the NEW head, and only then lands.
#  2. NO REVIEW → NO RECORD → NO LAND. A PR with no accepted-verdict record is
#     refused BEFORE any mutation (no update-branch, no record, no merge).
#  3. A CHANGED DIFF IS NEVER CARRIED. When record-review refuses (exit 3) the
#     rail STOPS, names the fresh review required, and never calls the land step.
#  4. THE MERGE IS NOT HAND-ROLLED: the rail never issues `gh pr merge`; it calls
#     admin-merge.sh, which owns the evidence and the decision.
#  5. A MERGE IS CONFIRMED, NOT INFERRED: admin-merge.sh exiting 0 while the PR
#     is still OPEN is a FAILURE (the #1359 false-success shape).
#  6. A NON-TERMINAL HEAD IS NOT LANDED: the wait is bounded and its expiry stops
#     the rail without recording or merging.
#  7. A DRAFT IS REFUSED BEFORE ANY CI WORK.
#  8. AN UNACCEPTED VERDICT IS REFUSED.
#  9. `--dry-run` MUTATES NOTHING (no update, no record, no comment, no merge).
# 10. A FRESH RECORD AT THE HEAD SKIPS update AND record (no dilution of an
#     unchanged head) and lands directly.
# 11. A FRESH REVIEW IS REQUIRED, NOT IMPROVISED: the rail calls record-review.sh
#     with the PRIOR head as its sha argument (the carry-forward input), never
#     the current head — passing the current head would record without any
#     equivalence proof.
#
# Hermetic: a fake gh, fake record-review and fake admin-merge serve every call;
# HOME is a temp dir so no real review record is read or written.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAIL="${ATOMIC_LAND_SUITE_RAIL:-$ROOT/scripts/atomic-land.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/atomic-land-suite.XXXXXX")"
checks=0
failures=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); echo "   ❌ $1"; failures=$((failures + 1)); }

[ -f "$RAIL" ] || { echo "❌ missing $RAIL"; exit 1; }

HEAD_OLD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_NEW="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REPO="daniel-ospina/agent-infra"

# ── fake gh ───────────────────────────────────────────────────────────────
FAKE="$TMP/fake-gh"
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
set -uo pipefail
SCEN="${SCEN:?SCEN must be set}"
printf '%s\n' "$*" >> "$SCEN/calls"

# current head: starts at the fixture and moves when update-branch succeeds
cur_head() { cat "$SCEN/head" 2>/dev/null || cat "$SCEN/head-old"; }
# A transient `mergeStateStatus` is modelled with a sequence file: line N feeds the
# Nth read (GitHub computes mergeability lazily, so UNKNOWN is usually temporary).
cur_state() {
  if [ -f "$SCEN/state-seq" ]; then
    local n; n=$(( $(cat "$SCEN/state-count" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$SCEN/state-count"
    sed -n "${n}p" "$SCEN/state-seq"
  else
    cat "$SCEN/state" 2>/dev/null || echo BEHIND
  fi
}

case "${1:-} ${2:-}" in
  "repo view")
    printf '%s\n' "$REPO_FIXTURE"; exit 0 ;;
  "pr update-branch")
    # Model the branch update: the head moves to head-new.
    [ "${SCEN_UPDATE_FAIL:-0}" = 1 ] && exit 1
    cp "$SCEN/head-new" "$SCEN/head"; exit 0 ;;
  "pr view")
    pr="${3:-}"; json=""; jqprog=""; prev=""
    for x in "$@"; do
      [ "$prev" = "--json" ] && json="$x"
      [ "$prev" = "--jq" ] && jqprog="$x"
      prev="$x"
    done
    case "$json" in
      *isDraft*)
        printf '%s\t%s\t%s\t%s\n' "$(cur_head)" "$(cat "$SCEN/base" 2>/dev/null || echo main)" \
          "$(cur_state)" "$(cat "$SCEN/draft" 2>/dev/null || echo false)"
        exit 0 ;;
      *baseRefName*)
        printf '%s\t%s\n' "$(cur_head)" "$(cat "$SCEN/base" 2>/dev/null || echo main)"; exit 0 ;;
      *headRefOid*)
        cur_head; exit 0 ;;
    esac
    exit 1 ;;
  "pr comment")
    exit 0 ;;
  "api"*)
    ep="${2:-}"; jqprog=""
    prev=""
    for x in "$@"; do [ "$prev" = "--jq" ] && jqprog="$x"; prev="$x"; done
    case "$ep" in
      */commits/*/check-runs)
        case "$jqprog" in
          *'!= "completed"'*) cat "$SCEN/pending" 2>/dev/null || echo 0 ;;
          *'== "completed"'*) cat "$SCEN/completed" 2>/dev/null || echo 1 ;;
          *) echo 0 ;;
        esac
        exit 0 ;;
      */compare/*)
        # model a base REWRITE inside the unit: the Nth compare returns the Nth line
        if [ -f "$SCEN/mb-seq" ]; then
          n=$(( $(cat "$SCEN/mb-count" 2>/dev/null || echo 0) + 1 ))
          printf '%s' "$n" > "$SCEN/mb-count"
          sed -n "${n}p" "$SCEN/mb-seq"
          exit 0
        fi
        cat "$SCEN/merge-base" 2>/dev/null || echo cccccccccccccccccccccccccccccccccccccccc
        exit 0 ;;
      */pulls/*)
        case "$jqprog" in
          *body*) cat "$SCEN/pr-body" 2>/dev/null || echo ""; exit 0 ;;
          *base*)
            if [ -f "$SCEN/base-tip-seq" ]; then
              n=$(( $(cat "$SCEN/base-tip-count" 2>/dev/null || echo 0) + 1 ))
              printf '%s' "$n" > "$SCEN/base-tip-count"
              sed -n "${n}p" "$SCEN/base-tip-seq"
              exit 0
            fi
            cat "$SCEN/base-tip" 2>/dev/null || echo 9999999999999999999999999999999999999999
            exit 0 ;;
        esac
        cat "$SCEN/merged" 2>/dev/null || echo OPEN; exit 0 ;;
    esac
    exit 1 ;;
esac
exit 1
FAKEEOF
chmod +x "$FAKE"

# ── fake record-review / admin-merge ──────────────────────────────────────
REC="$TMP/fake-record-review"
cat > "$REC" <<'RECEOF'
#!/usr/bin/env bash
set -uo pipefail
SCEN="${SCEN:?SCEN must be set}"
printf 'record-review %s\n' "$*" >> "$SCEN/calls"
case "${SCEN_RECORD_RC:-0}" in
  3) echo "carry-forward: no prior evidence for this PR's current diff (diff=deadbeefdeadbeef…) — the reviewed artifact cannot be shown unchanged" >&2; exit 3 ;;
esac
# The LIVE contract (#767): a zero exit leaves a record naming the PR's CURRENT
# head — either it already did (sha == head), or the carry-forward arm re-bound it
# because the reviewed diff is content-unchanged and the prior marker's signature
# verified. A fake that exits 0 WITHOUT writing a record models a delegate that
# does not implement the contract, and hides every binding defect from the suite.
if [ "${SCEN_RECORD_LOG:-}" = 1 ]; then
  echo "the reviewed diff is unchanged (diff=1111111111111111111111111111111111111111111111111111111111111111)"
fi
cur="$(cat "$SCEN/head" 2>/dev/null || printf '%s' "${HEAD:-}")"
# SCEN_RECORD_NO_WRITE models the FAIL-OPEN delegate: a zero exit that writes no
# record at all (record-review.sh fails open on a transient head read). This is
# the only path that exercises the rail's post-record binding guard.
if [ "${SCEN_RECORD_NO_WRITE:-0}" != 1 ]; then
  printf '{"pr":%s,"head_sha":"%s","verdict":"%s","repo":"%s","diff_sha256":"%s"}\n' \
    "$1" "$cur" "$3" "${4:-}" "1111111111111111111111111111111111111111111111111111111111111111" \
    > "$SCEN_RECORD_FILE"
fi
# Hooks that model a mutation landing AFTER the record step completes — i.e.
# inside the unit, between the record and the land (B9 head move, B10 repoint).
[ "${SCEN_RECORD_MOVES_HEAD:-0}" = 1 ] && printf '%s\n' "$HEAD_MOVED" > "$SCEN/head"
[ "${SCEN_RECORD_REPOINTS_BASE:-0}" = 1 ] && printf 'develop\n' > "$SCEN/base"
exit "${SCEN_RECORD_RC:-0}"
RECEOF
chmod +x "$REC"

ADM="$TMP/fake-admin-merge"
cat > "$ADM" <<'ADMEOF'
#!/usr/bin/env bash
set -uo pipefail
SCEN="${SCEN:?SCEN must be set}"
printf 'admin-merge %s\n' "$*" >> "$SCEN/calls"
exit "${SCEN_ADMIN_RC:-0}"
ADMEOF
chmod +x "$ADM"

# ── harness ───────────────────────────────────────────────────────────────
# new_scen: a scenario dir + a temp HOME carrying the review record fixture.
# A fixture gate key and a marker that is GENUINELY signed with it. The rail verifies
# the signature, so a fixture that only imitates the shape would (correctly) be
# refused as unverifiable.
GATE_KEY_FIXTURE="test-gate-key-arbitrary-0001"
marker_fixture() { # <pr> <verdict> <sha> [diff-hex]
  local pr="$1" v="$2" sha="$3"
  local diff="${4:-1111111111111111111111111111111111111111111111111111111111111111}"
  local text="review recorded: reviews/${pr}.json verdict=${v} @ ${sha} diff=${diff} (${REPO})"
  printf '%s sig=%s\n' "$text" \
    "$(printf '%s' "$text" | openssl dgst -sha256 -hmac "$GATE_KEY_FIXTURE" | awk '{print $NF}')"
}

new_scen() {
  SCEN="$TMP/scen-$1"
  # reset every scenario-scoped switch (a leak between scenarios is a test bug)
  SCEN_RECORD_RC=0; SCEN_RECORD_LOG=; SCEN_ADMIN_RC=0; ATOMIC_LAND_CONFIRM_MAX=60
  SCEN_RECORD_NO_WRITE=0
  SCEN_RECORD_MOVES_HEAD=0; SCEN_RECORD_REPOINTS_BASE=0; HEAD_MOVED="cccccccccccccccccccccccccccccccccccccccc"
  unset mb_seq 2>/dev/null || true
  rm -f "$SCEN/state-seq" "$SCEN/state-count" 2>/dev/null || true
  mkdir -p "$SCEN" "$SCEN/home/.pi/agent/reviews"
  printf '%s\n' "$HEAD_OLD" > "$SCEN/head-old"
  printf '%s\n' "$HEAD_NEW" > "$SCEN/head-new"
  printf '%s\n' "$HEAD_OLD" > "$SCEN/head"
  printf 'main\n' > "$SCEN/base"
  printf 'BEHIND\n' > "$SCEN/state"
  printf 'false\n' > "$SCEN/draft"
  printf '0\n' > "$SCEN/pending"
  printf '5\n' > "$SCEN/completed"
  printf 'MERGED\n' > "$SCEN/merged"
  printf 'cccccccccccccccccccccccccccccccccccccccc\n' > "$SCEN/merge-base"
  printf '9999999999999999999999999999999999999999\n' > "$SCEN/base-tip"
  mkdir -p "$SCEN/tmp"
  : > "$SCEN/calls"
  # default fixture record: verdict clean at the OLD head
  SCEN_RECORD_FILE="$SCEN/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
  printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s"}\n' "$HEAD_OLD" "$REPO" \
    > "$SCEN_RECORD_FILE"
  # Gate key + a GENUINELY SIGNED marker with a diff= identity (the post-#767
  # shape). The rail VERIFIES the signature, so the fixture must really sign:
  # a body that merely LOOKS like a marker is not evidence (it is attacker-writable).
  printf '%s' "$GATE_KEY_FIXTURE" > "$SCEN/home/.pi/agent/.ai-review-gate-key"
  marker_fixture 42 clean "$HEAD_OLD" > "$SCEN/pr-body"
}

run_rail() { # <extra args...>
  SCEN="$SCEN" HOME="$SCEN/home" REPO_FIXTURE="$REPO" HEAD_MOVED="$HEAD_MOVED" TMPDIR="$SCEN/tmp" \
  SCEN_RECORD_RC="${SCEN_RECORD_RC:-0}" SCEN_RECORD_LOG="${SCEN_RECORD_LOG:-}" \
  SCEN_RECORD_FILE="$SCEN_RECORD_FILE" \
  SCEN_RECORD_NO_WRITE="${SCEN_RECORD_NO_WRITE:-0}" \
  SCEN_RECORD_MOVES_HEAD="${SCEN_RECORD_MOVES_HEAD:-0}" \
  SCEN_RECORD_REPOINTS_BASE="${SCEN_RECORD_REPOINTS_BASE:-0}" \
  SCEN_ADMIN_RC="${SCEN_ADMIN_RC:-0}" ATOMIC_LAND_CONFIRM_MAX="${ATOMIC_LAND_CONFIRM_MAX:-60}" \
  ATOMIC_LAND_GH="$FAKE" ATOMIC_LAND_RECORD_SH="$REC" ATOMIC_LAND_ADMIN_MERGE="$ADM" \
    bash "$RAIL" "$@" >"$SCEN/out" 2>"$SCEN/err"
}

calls() { cat "$SCEN/calls"; }
called() { grep -qF -- "$1" "$SCEN/calls"; }
count_call() { grep -cF -- "$1" "$SCEN/calls"; }

# ═══ 1. the ordered atomic unit on a BEHIND PR ═══════════════════════════
echo "── 1. BEHIND PR with an unchanged diff: update → verify → record → land"
new_scen happy
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "the unit completes (rc 0)" || fail "expected rc 0, got $rc ($(tail -1 "$SCEN/err"))"
called "pr update-branch 42" && pass "step 1: the branch was updated" || fail "step 1: update-branch was never called"
called "record-review 42 $HEAD_OLD clean $REPO" \
  && pass "step 3: record-review got the PRIOR head (the carry-forward input), not the new head" \
  || fail "step 3: record-review was not called with the prior head + verdict (calls: $(calls))"
called "admin-merge 42" && pass "step 4: the land step is admin-merge.sh" || fail "step 4: admin-merge.sh was never called"
# ordering: update before record before land
awk '/pr update-branch/{u=NR} /record-review/{r=NR} /admin-merge/{a=NR} END{exit !(u<r && r<a)}' "$SCEN/calls" \
  && pass "the steps ran in order (update < record < land)" \
  || fail "the steps are out of order (calls: $(calls))"
called "reused verdict" && pass "the reuse was cited" || fail "no reuse citation comment was posted"
# the citation is PROSE — the review-marker format is a cross-repo contract, so
# this rail must never emit a marker segment it would inherit a land order for.
grep -qF -- '<!--' "$SCEN/calls" && fail "the rail wrote a marker segment (cross-repo land order)" \
  || pass "the citation is prose only — no marker segment written by the rail"

# ═══ 2. a changed diff is never carried ══════════════════════════════════
echo "── 2. record-review refuses (exit 3): STOP, no land, name the fresh review"
new_scen changed
SCEN_RECORD_RC=3
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "the rail stops (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "the land step ran on an unprovable diff" || pass "the land step did NOT run"
grep -q "FRESH review" "$SCEN/err" && pass "the refusal names the fresh review required" || fail "the refusal does not name a fresh review"
# #1362 D1 — a PARTIAL INSTALL is a second cause of exit 3, and blaming the diff
# for it would send a lane to re-review an unchanged artifact (the exact false
# obligation D1 removes). The fixture's record script has no sibling normalizer,
# so the diagnostic must fire here. REGRESSION-SENSITIVE: removing the
# `[ ! -f "$DIFF_NORMALIZER_SH" ]` guard leaves the suite red.
grep -q "diff normalizer" "$SCEN/err" \
  && pass "12/D1: a missing producer normalizer is named (partial install, not a changed diff)" \
  || fail "12/D1: the missing diff normalizer was NOT named — a partial install would masquerade as a changed diff"

# ═══ 3. no record → refuse before any mutation ═══════════════════════════
echo "── 3. no review record: refuse before ANY mutation"
new_scen norec
rm -f "$SCEN/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "mutated before the precondition (update-branch)" || pass "no update-branch before the precondition"
called "admin-merge" && fail "landed without a record" || pass "no land without a record"
grep -q "no review record" "$SCEN/err" && pass "the refusal names the missing record" || fail "the refusal does not name the missing record"

# ═══ 4. a draft is refused ════════════════════════════════════════════════
echo "── 4. a draft is refused before any CI work"
new_scen draft
printf 'true\n' > "$SCEN/draft"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "did CI work on a draft" || pass "no mutation on a draft"
grep -q "DRAFT" "$SCEN/err" && pass "the refusal names the draft" || fail "the refusal does not name the draft"

# ═══ 5. an unaccepted verdict is refused ═════════════════════════════════
echo "── 5. an unaccepted verdict is refused"
new_scen badverdict
printf '{"pr":42,"head_sha":"%s","verdict":"pending","repo":"%s"}\n' "$HEAD_OLD" "$REPO" \
  > "$SCEN/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
# Give the PR a VALIDLY SIGNED marker carrying the SAME (unaccepted) verdict, so
# the B5 update guard passes and this scenario isolates the VERDICT check: with
# the check disabled, nothing else stands between the record and a land.
marker_fixture 42 pending "$HEAD_OLD" > "$SCEN/pr-body"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed on an unaccepted verdict" || pass "no land on an unaccepted verdict"

# ═══ 6. a merge is confirmed, not inferred ═══════════════════════════════
echo "── 6. admin-merge exits 0 but the PR is still OPEN: FAILURE, not success"
new_scen unmerged
printf 'OPEN\n' > "$SCEN/merged"
SCEN_RECORD_LOG=1
ATOMIC_LAND_CONFIRM_MAX=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "the rail reports failure (rc 1)" || fail "expected rc 1, got $rc (a false success)"
grep -q "NOT confirmed" "$SCEN/err" && pass "the failure names the unconfirmed merge" || { fail "the failure does not name the unconfirmed merge"; echo "      --- err ---"; sed 's/^/      /' "$SCEN/err"; }

# ═══ 7. a non-terminal head is not landed ════════════════════════════════
echo "── 7. the terminal-check wait is bounded; its expiry stops the rail"
new_scen pending
printf '3\n' > "$SCEN/pending"
run_rail 42 --repo "$REPO" --poll 0 --wait-timeout 0
rc=$?
[ "$rc" -eq 1 ] && pass "stops on wait expiry (rc 1)" || fail "expected rc 1, got $rc"
called "record-review" && fail "recorded without terminal checks" || pass "no record before terminal checks"
called "admin-merge" && fail "landed without terminal checks" || pass "no land before terminal checks"
grep -q "not terminal" "$SCEN/err" && pass "the refusal names the wait" || fail "the refusal does not name the wait"

# ═══ 8. dry-run mutates nothing ══════════════════════════════════════════
echo "── 8. --dry-run mutates nothing"
new_scen dryrun
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0 --dry-run
rc=$?
[ "$rc" -eq 0 ] && pass "dry-run completes (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" && fail "dry-run updated the branch" || pass "no update in dry-run"
called "record-review" && fail "dry-run recorded" || pass "no record in dry-run"
called "pr comment" && fail "dry-run posted a comment" || pass "no comment in dry-run"
grep -q "admin-merge 42 --repo $REPO --dry-run" "$SCEN/calls" \
  && pass "the land step is invoked read-only (--dry-run)" \
  || fail "the land step was not invoked with --dry-run (calls: $(calls))"

# ═══ 9. a fresh record at the head skips update and record ═══════════════
echo "── 9. a fresh record at the head is not diluted; it lands directly"
new_scen fresh
printf '%s\n' "$HEAD_NEW" > "$SCEN/head"
printf 'CLEAN\n' > "$SCEN/state"
printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s"}\n' "$HEAD_NEW" "$REPO" \
  > "$SCEN/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" && fail "updated a PR that was not BEHIND" || pass "no update (not BEHIND)"
called "record-review" && fail "re-recorded an unchanged head (dilutes the evidence)" || pass "no re-record of a fresh head"
called "admin-merge 42" && pass "landed directly" || fail "did not land"

# ═══ 10. the merge is never hand-rolled, and the rail never reads protection ═
echo "── 10. the rail never issues a raw merge, and has no branch-protection dependency"
new_scen norewrite
for s in "$TMP/scen-happy" "$TMP/scen-fresh" "$TMP/scen-dryrun"; do
  grep -qE '(^|[[:space:]])pr[[:space:]]+merge([[:space:]]|$)' "$s/calls" \
    && fail "a raw \`gh pr merge\` was issued from $(basename "$s")" \
    || pass "no raw \`gh pr merge\` in $(basename "$s")"
  grep -qE 'protection|required_status_checks' "$s/calls" \
    && fail "the rail read a branch-protection setting from $(basename "$s") (undeclared dependency on strict)" \
    || pass "no branch-protection read in $(basename "$s") (no strict dependency)"
done

# ═══ 11. B9 — the head must not move between the record and the land ════
echo "── 11. the head moving between the record and the land stops the unit"
new_scen headmoved
SCEN_RECORD_MOVES_HEAD=1
HEAD_MOVED="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0 --max-rounds 1
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed after the head moved (B9 fail-open)" || pass "did NOT land after the head moved"
grep -q "head moved between the record" "$SCEN/err" && pass "the stop names the mid-unit head move" || fail "the stop does not name the head move"

# ═══ 12. B10 — the BASE must not move inside the unit ══════════════════
echo "── 12. a base REPOINT inside the unit stops the unit (B10)"
new_scen baserepoint
SCEN_RECORD_REPOINTS_BASE=1
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed after the base was repointed (B10 fail-open)" || pass "did NOT land after the base was repointed"
grep -q "base was repointed" "$SCEN/err" && pass "the stop names the repoint" || fail "the stop does not name the repoint"

# ═══ 13. B10 — a base REWRITE (same branch name) inside the unit ════════
echo "── 13. a base REWRITE (merge base moves, same branch) stops the unit"
new_scen baserewrite
printf 'cccccccccccccccccccccccccccccccccccccccc\ndddddddddddddddddddddddddddddddddddddddd\n' > "$SCEN/mb-seq"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed after the base was rewritten (B10 fail-open)" || pass "did NOT land after the base was rewritten"
grep -q "merge base moved" "$SCEN/err" && pass "the stop names the merge-base move" || fail "the stop does not name the merge-base move"

# ═══ 14. B10 — a PRE-UNIT repoint on a FRESH record (clean-low) ═════════
echo "── 14. a fresh record whose merge_base_sha disagrees with the live base is refused"
new_scen preunit
printf '%s\n' "$HEAD_NEW" > "$SCEN/head"
printf 'CLEAN\n' > "$SCEN/state"
printf '{"pr":42,"head_sha":"%s","verdict":"clean-low","merge_base_sha":"ffffffffffffffffffffffffffffffffffffffff","repo":"%s"}\n' \
  "$HEAD_NEW" "$REPO" > "$SCEN/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1)" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "mutated before the base-binding check" || pass "refused before any mutation"
called "admin-merge" && fail "landed with a record bound to a different base" || pass "did NOT land on a base-mismatched record"
grep -q "certified against merge base" "$SCEN/err" && pass "the stop names the record's base" || fail "the stop does not name the record's base"

# ═══ 15. B10 under strict OFF — no BEHIND, fresh record, base rewritten ══
# The live criterion ("lands a real BEHIND PR") only ever exercises strict ON.
# This case has NO `BEHIND` (state CLEAN) and a FRESH record, so the rail updates
# and records nothing — and the base is still rewritten between verify and land.
# It must STILL refuse; that is the strict-off window the rail exists to make
# unnecessary, so the binding must not depend on the protection setting.
echo "── 15. a base rewrite with NO BEHIND (strict off) still stops the unit"
new_scen strictoff
printf '%s\n' "$HEAD_NEW" > "$SCEN/head"
printf 'CLEAN\n' > "$SCEN/state"
printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s"}\n' "$HEAD_NEW" "$REPO" \
  > "$SCEN/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
printf 'cccccccccccccccccccccccccccccccccccccccc\ndddddddddddddddddddddddddddddddddddddddd\n' > "$SCEN/mb-seq"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1) with no BEHIND and a fresh record" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed after a strict-off base rewrite (the window bypass)" || pass "did NOT land on the strict-off base rewrite"
called "pr update-branch" && fail "updated a non-BEHIND PR" || pass "no update (BEHIND was absent, as in the window)"
grep -q "merge base moved" "$SCEN/err" && pass "the stop names the merge-base move" || fail "the stop does not name the merge-base move"

# ═══ 16. B12 — a concurrent merge advances the base after verification ═══
# Two rails (or two lanes) verify against base X; A merges; the base becomes X+A;
# B would land via --admin onto a base its checks never covered. The merge base is
# UNCHANGED, so B10 does not fire: this is the multi-agent form of the race, and
# it must be re-verified (or refused), never landed.
echo "── 16. a concurrent base ADVANCE after verification stops the unit (B12)"
new_scen baseadvance
printf '9999999999999999999999999999999999999999\n8888888888888888888888888888888888888888\n' > "$SCEN/base-tip-seq"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0 --max-rounds 1
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1) — did not land on an unverified base" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed after the base advanced (B12 fail-open)" || pass "did NOT land after the base advanced"
grep -qi "advanced after verification" "$SCEN/err" && pass "the stop names the advance" || fail "the stop does not name the advance"

# ═══ 16b. B12 — the CAPTURE read itself must fail closed ═════════════════
# An empty base-tip read is a transient API failure, not a licence to skip the
# binding. The pre-land arm runs only when the captured tip is non-empty, so an
# unreadable capture would silently disable B12 — and the unit would land on a
# base its checks never covered (the same fail-open, reached by a different
# path). An unreadable tip must STOP at capture, exactly like the merge base.
echo "── 16b. an UNREADABLE base tip at capture stops the unit (B12, fail-closed)"
new_scen basetipunreadable
printf '\n8888888888888888888888888888888888888888\n' > "$SCEN/base-tip-seq"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1) — refused to certify without a base binding" || fail "expected rc 1, got $rc (landed with NO base binding)"
called "admin-merge" && fail "landed with an unreadable base tip — B12 was silently skipped" || pass "did NOT land without a base-binding capture"
grep -qi "could not read the base tip" "$SCEN/err" && pass "the stop names the unreadable base tip" || fail "the stop does not name the unreadable base tip"

# ═══ 17. B11 — two rails on the same PR must not interleave ═════════════
echo "── 17. a held per-PR lock refuses before any mutation (B11)"
new_scen lock
LOCK="$SCEN/home/.pi/agent/locks/atomic-land-daniel-ospina-agent-infra-42.lock"
mkdir -p "$LOCK" && printf '%s\n' "$$" > "$LOCK/pid"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "mutated while another rail held the lock" || pass "no mutation while locked"
called "admin-merge" && fail "landed while another rail held the lock" || pass "no land while locked"
grep -qi "already running" "$SCEN/err" && pass "the refusal names the concurrent rail" || fail "the refusal does not name the concurrent rail"
rm -rf "$LOCK"

# ═══ 17b. B6/B12 — an UNKNOWN merge state is not "up to date" ═══════════
echo "── 17b. an UNKNOWN mergeStateStatus stops the unit (B6/B12)"
new_scen unknownstate
printf 'UNKNOWN\n' > "$SCEN/state"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1)" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "mutated on an undetermined merge state" || pass "no update on an undetermined state"
called "admin-merge" && fail "landed on an undetermined merge state (B6/B12 fail-open)" || pass "did NOT land on an undetermined merge state"
grep -qi "still undetermined" "$SCEN/err" && pass "the stop names the undetermined state" || fail "the stop does not name the undetermined state"

printf 'UNKNOWN\n' > "$SCEN/state"
printf 'UNKNOWN\nUNKNOWN\nCLEAN\n' > "$SCEN/state-seq"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "re-polled the transient UNKNOWN and settled (rc 0)" || fail "expected rc 0, got $rc ($(tail -1 "$SCEN/err"))"
called "admin-merge" && pass "the unit proceeded once the state settled" || fail "did not proceed after the state settled"
rm -f "$SCEN/state-seq" "$SCEN/state-count"

# ═══ 17c. B11 — a pid-less (young) lock is LIVE, not stale ═══════════════
# The lock directory exists before the pid is written, so a rail in that window
# sees no pid. Reading that as "stale" reclaims a LIVE holder and both rails land.
echo "── 17c. a pid-less young lock refuses (B11 TOCTOU)"
new_scen locknopid
LOCK2="$SCEN/home/.pi/agent/locks/atomic-land-daniel-ospina-agent-infra-42.lock"
mkdir -p "$LOCK2"   # no pid file — the mkdir→printf window
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed by reclaiming a pid-less live lock (B11 fail-open)" || pass "did NOT land by reclaiming a pid-less lock"
grep -qi "no pid yet" "$SCEN/err" && pass "the refusal names the pid-less holder" || fail "the refusal does not name the pid-less holder"
rm -rf "$LOCK2"

# ═══ 17d. B8 — a zero exit that writes no record must be refused ══════
# The live delegate fails OPEN when it cannot read the PR's head. A rail that
# trusted the exit status would land with no record for the head it merges.
echo "── 17d. a zero exit that writes no record for HEAD is refused (B8)"
new_scen liardelegate
SCEN_RECORD_NO_WRITE=1
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "landed with no record for the head it would land (B8 fail-open)" || pass "did NOT land without a record naming HEAD"
grep -q "the record names" "$SCEN/err" && pass "the stop names the record/head mismatch" || fail "the stop does not name the record/head mismatch"
grep -qF "reused verdict" "$SCEN/calls" && fail "published a reuse citation BEFORE the binding was verified" || pass "no reuse citation published before verification"

# ═══ 17e. B11 — a STALE lock is reclaimed and the unit proceeds ═════════
echo "── 17e. a dead-pid lock is reclaimed and the unit proceeds (B11)"
new_scen stalereclaim
LOCK3="$SCEN/home/.pi/agent/locks/atomic-land-daniel-ospina-agent-infra-42.lock"
mkdir -p "$LOCK3" && printf '999999\n' > "$LOCK3/pid"   # a pid that is certainly not alive
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "reclaimed and completed (rc 0)" || fail "expected rc 0, got $rc ($(tail -1 "$SCEN/err"))"
called "admin-merge" && pass "the unit landed after reclaiming a stale lock" || fail "did not proceed after reclaiming a stale lock"

# ═══ 17f. B5 — never spend an attestation the unit cannot restore ═══════
# Measured cost of NOT checking this: a 22-PR sweep invalidated 17 fresh
# attestations and landed 0. A pre-#767 marker is signed but carries no `diff=`,
# so the carry-forward can never re-bind it — updating is destructive with
# certainty.
echo "── 17f. a pre-#767 record refuses to be spent on a branch update (B5)"
new_scen precarry
printf 'review recorded: reviews/42.json verdict=clean @ %s (%s) sig=%s\n' \
  "$HEAD_OLD" "$REPO" "3333333333333333333333333333333333333333333333333333333333333333" > "$SCEN/pr-body"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1) — refused to destroy an unrestorable attestation" || fail "expected rc 1, got $rc ($(tail -1 "$SCEN/err"))"
called "pr update-branch" && fail "updated the branch and spent the attestation (B5)" || pass "did NOT update (the record would have been destroyed)"
called "admin-merge" && fail "landed after spending the attestation" || pass "did not land"
grep -qi "no VERIFIABLE signed marker with a diff=" "$SCEN/err" && pass "the stop names the missing identity" || fail "the stop does not name the missing identity"

# 17g. The PR body is ATTACKER-WRITABLE, so a marker that merely LOOKS right is not
# evidence. A forged line (right shape, signature that does not verify) must not be
# accepted as proof the record can be restored — the producer would refuse to carry
# it, and the update would have spent the attestation for nothing.
echo "── 17g. a FORGED marker (valid shape, invalid signature) is not evidence (B5)"
new_scen forgedcarry
printf 'review recorded: reviews/42.json verdict=clean @ %s diff=%s (%s) sig=%s\n' \
  "$HEAD_OLD" "1111111111111111111111111111111111111111111111111111111111111111" "$REPO" \
  "4444444444444444444444444444444444444444444444444444444444444444" > "$SCEN/pr-body"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1) — a shape match is not evidence" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "spent the attestation on a FORGED marker (B5)" || pass "did NOT update on a forged marker"
called "admin-merge" && fail "landed on a forged marker" || pass "did not land"

# 17h. With no gate key the producer can never carry a previous marker, so the rail
# must not spend the attestation: fail closed.
echo "── 17h. no gate key available → refuse to spend (B5)"
new_scen nokey
rm -f "$SCEN/home/.pi/agent/.ai-review-gate-key"   # the signed body stays; the KEY is gone
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1) when no key is available" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "spent the attestation with no way to restore it (B5)" || pass "did NOT update without a key"
grep -qi "no review gate key is available" "$SCEN/err" && pass "the stop names the missing key" || fail "the stop does not name the missing key"

# 17i. DECLARED RESIDUAL (B, fail-closed). The producer APPENDS a marker per record
# and never removes old ones, so bodies accumulate lines. The rail cannot tell a
# stale-diff line from a live-diff one (that needs the LIVE diff = the producer's
# equivalence decision), so when the first matching line is stale it REFUSES even
# though the producer might carry from a later line. That is an over-block:
# friction, recoverable and visible. The alternative — accepting any later line —
# SPENDS an attestation the producer then refuses to carry (silent destruction,
# the 22-updated / 17-invalidated / 0-landed mode this guard exists to prevent).
# This scenario pins the CHOSEN behaviour so a future widening cannot land silently.
echo "── 17i. stale FIRST marker blocks a possibly-restorable later marker (declared B residual)"
new_scen multimarker
# older lines come FIRST: stale/unverifiable line, then the genuine one
printf 'review recorded: reviews/42.json verdict=clean @ %s diff=%s (%s) sig=%s\n' \
  "$HEAD_OLD" "9999999999999999999999999999999999999999999999999999999999999999" "$REPO" \
  "5555555555555555555555555555555555555555555555555555555555555555" > "$SCEN/pr-body"
marker_fixture 42 clean "$HEAD_OLD" >> "$SCEN/pr-body"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1) — fail-closed: no spend on an unverifiable first line" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "SPENT the attestation on a possibly-stale marker (fail-open)" || pass "did NOT update — the attestation is intact"

# 17j. …and the same body with the key rotated so NO line verifies also refuses.
echo "── 17j. stale FIRST marker + unverifiable second marker → refuse (B5)"
new_scen multimarkerbad
printf 'review recorded: reviews/42.json verdict=clean @ %s diff=%s (%s) sig=%s\n' \
  "$HEAD_OLD" "9999999999999999999999999999999999999999999999999999999999999999" "$REPO" \
  "5555555555555555555555555555555555555555555555555555555555555555" > "$SCEN/pr-body"
marker_fixture 42 clean "$HEAD_OLD" >> "$SCEN/pr-body"
printf '%s' "a-completely-different-key-0002" > "$SCEN/home/.pi/agent/.ai-review-gate-key"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1) — no line verified under the current key" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "spent the attestation under a rotated key (B5)" || pass "did NOT update"

# ═══ 18. mutation coverage for the declared threat surface ═══════════════
# The adversarial bound is the DECLARED surface, not reviewer exhaustion: every
# class B1-B12 must be covered by a test that FAILS against the revision before
# its fix. This section mutates the rail and asserts the suite reddens. A mutation
# that leaves the suite green means the class is NOT covered.
if [ "${ATOMIC_LAND_MUTATIONS:-1}" != 0 ]; then
  echo "── 18. mutation coverage — each declared bypass class must be caught"
  MUT="$TMP/mut"; mkdir -p "$MUT"
  mutate_and_expect_fail() { # <name> <perl-expr>
    local name="$1"
    local expr="$2"
    local src="$MUT/$name.sh"
    cp "$RAIL" "$src"
    if ! perl -0pi -e "$expr" "$src" 2>/dev/null; then fail "mutation $name: perl failed"; return; fi
    if cmp -s "$src" "$RAIL"; then fail "mutation $name reddened nothing — the mutation did not apply"; return; fi
    ATOMIC_LAND_MUTATIONS=0 ATOMIC_LAND_SUITE_RAIL="$src" bash "$0" >"$MUT/$name.log" 2>&1
    if [ $? -ne 0 ]; then
      pass "mutation $name reddens the suite (class covered)"
    else
      fail "mutation $name did NOT redden the suite (class NOT covered)"
    fi
  }
  # B1: pass the CURRENT head to record-review instead of the prior head
  mutate_and_expect_fail B1   's/"\$RECORD_SH" "\$PR" "\$prior"/"$RECORD_SH" "$PR" "$HEAD"/'
  # B2a: drop the record precondition
  mutate_and_expect_fail B2a  's/if ! read_record; then/if false; then/'
  # B2b: accept every verdict (BOTH the pre-unit gate and the post-record re-read guard)
  mutate_and_expect_fail B2b  's/if ! verdict_accepted "\$RECORD_VERDICT"; then/if false; then/g'
  # B3: add a hand-rolled --admin merge beside the mandated rail
  mutate_and_expect_fail B3   's/bash "\$ADMIN_MERGE" "\$PR"/"$GH" pr merge "$PR" --admin; bash "$ADMIN_MERGE" "$PR"/'
  # B4: never confirm the merge
  mutate_and_expect_fail B4   's/confirm_merged\(\) \{/confirm_merged() { return 0;/'
  # B5: allow a draft
  mutate_and_expect_fail B5   's/if \[ "\$IS_DRAFT" = "true" \]; then/if false; then/'
  # B8b: trust the delegate's exit status instead of re-reading the record
  mutate_and_expect_fail B8b  's/^  if \[ "\$RECORD_HEAD" != "\$HEAD" \]; then/  if false; then/m'
  # B5b: spend an attestation without checking it can be re-bound
  mutate_and_expect_fail B5b  's/if \[ "\$RECORD_HEAD" = "\$HEAD" \] && ! pr_has_carry_evidence; then/if false; then/'
  # B5c: accept a marker on SHAPE alone — the PR body is attacker-writable
  mutate_and_expect_fail B5c  's/\[ "\$sig" = "\$expect" \]/[ -n "\$sig" ]/'
  # B6c: do not re-poll a transient UNKNOWN — a computed-later state false-blocks
  mutate_and_expect_fail B6c  's/while \[ "\$t" -lt "\${ATOMIC_LAND_UNKNOWN_POLLS:-5}" \]; do/while false; do/'
  # B6b: read an undetermined merge state as "up to date" and certify anyway
  mutate_and_expect_fail B6b  's/^(\s*)stop "the merge state of .*$/$1return 3/m'
  # B11b: reclaim a pid-less lock immediately — the mkdir→pid TOCTOU
  mutate_and_expect_fail B11b 's/if \[ "\$age" -lt "\${ATOMIC_LAND_LOCK_GRACE:-60}" \]; then/if false; then/'
  # B6: never stop on the terminal-check wait expiry
  mutate_and_expect_fail B6   's/^      stop "the checks at.*$/      return 0/m'
  # B7: make --dry-run a no-op (the inspection path starts mutating)
  mutate_and_expect_fail B7   's/--dry-run\)      DRY_RUN=1; shift ;;/--dry-run)      DRY_RUN=0; shift ;;/'
  # B8: treat every record as fresh
  mutate_and_expect_fail B8   's/if \[ "\$RECORD_HEAD" = "\$HEAD" \]; then/if true; then/'
  # B9: never re-check the head before landing
  mutate_and_expect_fail B9   's/if \[ "\$now" != "\$HEAD" \]; then/if false; then/'
  # B10a: never re-check the base BRANCH before landing
  mutate_and_expect_fail B10a 's/if \[ "\$now_base" != "\$CERT_BASE" \]; then/if false; then/'
  # B10b: never re-check the base's MERGE BASE before landing
  mutate_and_expect_fail B10b 's/if \[ -z "\$now_mb" \] || \[ "\$now_mb" != "\$CERT_MB" \]; then/if false; then/'
  # B10c: never compare the record's own merge base to the live one (pre-unit)
  mutate_and_expect_fail B10c 's/if \[ -z "\$live_mb" \] || \[ "\$live_mb" != "\$RECORD_MB" \]; then/if false; then/'
  # B12: never detect a concurrent base ADVANCE
  mutate_and_expect_fail B12  's/if \[ "\$now_tip" != "\$CERT_BASE_TIP" \]; then/if false; then/'
  # B12b: the CAPTURE read must fail closed — an empty capture must not silently
  # disable the pre-land comparison (the path the reviewer reproduced).
  mutate_and_expect_fail B12b 's/if \[ -z "\$CERT_BASE_TIP" \]; then/if false; then/'
  # B11: never take the per-PR lock
  mutate_and_expect_fail B11  's/\[ "\$DRY_RUN" -eq 0 \] && acquire_lock//'
  # D1d (#1362): the partial-install diagnostic is not a bypass class, but it is
  # a D1 behavior the suite pins — removing its guard must redden scenario 2.
  mutate_and_expect_fail D1d  's/if \[ ! -f "\$DIFF_NORMALIZER_SH" \]; then/if false; then/'
fi

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks atomic-land test(s) failed"
  exit 1
fi
echo "✅ all $checks atomic-land tests passed"
