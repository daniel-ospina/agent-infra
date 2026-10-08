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
#     the rail without recording or merging. The bound is a WALL CLOCK, so it
#     holds even when `--poll 0` is passed (#1395 item 1 — see 7b), and it is
#     CAPPED, so a bound `[` cannot compare is REFUSED rather than silently
#     inert (7c).
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
      *mergeable*)
        # #1565: read ONLY when the live `strict` read positively said false.
        # ⛔ The REAL `gh pr view --json mergeable` prints the GraphQL ENUM, not a
        # boolean (MEASURED: `MERGEABLE`). This fixture must speak the CLI's language:
        # when it spoke REST's (`true`) the suite certified a predicate that could
        # never match in production — the #1565 review P0.
        # The DEFAULT when the fixture is absent is deliberately the NON-matching token:
        # defaulting to MERGEABLE would let a future scenario that sets strict=false and
        # forgets the fixture silently take the SKIP path instead of reddening (round-2
        # review). Absent ⇒ unreadable ⇒ refresh — the fail-closed direction.
        cat "$SCEN/mergeable" 2>/dev/null || echo UNKNOWN; exit 0 ;;
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
      */branches/*/protection*)
        # #1565: the DECLARED live `strict` read. An ABSENT fixture models the real
        # 404/403 (protection unconfigured, or a token without admin on the repo) —
        # the fail-closed default that keeps every pre-existing scenario refreshing.
        [ -f "$SCEN/strict" ] || exit 1
        cat "$SCEN/strict"; exit 0 ;;
      */commits/*/check-runs*)
        # A read without --paginate sees ONE page only. The rail's terminal verdict
        # must be computed over ALL pages, so the fake models the page boundary:
        # the fixture is multi-line (one line per page), and only a paginated read
        # is served every line. A single-line fixture is unaffected.
        page() { local f="$1"; shift; if [[ " $* " == *" --paginate "* ]]; then cat "$SCEN/$f"; else head -1 "$SCEN/$f"; fi; }
        case "$jqprog" in
          *'!= "completed"'*) page pending "$@" 2>/dev/null || echo 0 ;;
          *'== "completed"'*) page completed "$@" 2>/dev/null || echo 1 ;;
          *) echo 0 ;;
        esac
        exit 0 ;;
      */compare/*)
        # the MEASURED distance (B13) — a DISTINCT field from the merge base, read
        # by its own jq program. Without this arm the harness would answer the
        # behind_by read with a merge-base sha (non-numeric), so behind_by_of would
        # report "unreadable" in EVERY scenario and the drift-refresh path could
        # never be exercised at all.
        case "$jqprog" in
          *behind_by*) cat "$SCEN/behind" 2>/dev/null || echo 0; exit 0 ;;
        esac
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
  # #1565 fixtures: absent by default, i.e. UNREADABLE protection (the fail-closed
  # default) so every pre-existing scenario keeps refreshing exactly as before.
  rm -f "$SCEN/strict" "$SCEN/mergeable" 2>/dev/null || true
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
  printf '0\n' > "$SCEN/behind"
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

# The fixture environment plus the rail invocation, ending in `exec` so the
# CALLER's process BECOMES the rail. That indirection is what lets the watchdog
# kill the rail itself: `( run_rail ... ) &` backgrounds a SUBSHELL, and killing
# the subshell leaves the rail orphaned — and a rail stuck on the wait bound
# never exits, so the orphan spins forever, one per suite run (#1395 P1, measured
# with PPID 1). This helper is only ever called in a subshell or backgrounded, so
# the `exec` cannot replace this test script.
rail_exec() { # <extra args...>
  SCEN="$SCEN" HOME="$SCEN/home" REPO_FIXTURE="$REPO" HEAD_MOVED="$HEAD_MOVED" TMPDIR="$SCEN/tmp" \
  SCEN_RECORD_RC="${SCEN_RECORD_RC:-0}" SCEN_RECORD_LOG="${SCEN_RECORD_LOG:-}" \
  SCEN_RECORD_FILE="$SCEN_RECORD_FILE" \
  SCEN_RECORD_NO_WRITE="${SCEN_RECORD_NO_WRITE:-0}" \
  SCEN_RECORD_MOVES_HEAD="${SCEN_RECORD_MOVES_HEAD:-0}" \
  SCEN_RECORD_REPOINTS_BASE="${SCEN_RECORD_REPOINTS_BASE:-0}" \
  SCEN_ADMIN_RC="${SCEN_ADMIN_RC:-0}" ATOMIC_LAND_CONFIRM_MAX="${ATOMIC_LAND_CONFIRM_MAX:-60}" \
  ATOMIC_LAND_GH="$FAKE" ATOMIC_LAND_RECORD_SH="$REC" ATOMIC_LAND_ADMIN_MERGE="$ADM" \
    exec bash "$RAIL" "$@"
}

run_rail() { # <extra args...>
  ( rail_exec "$@" >"$SCEN/out" 2>"$SCEN/err" )
}

calls() { cat "$SCEN/calls"; }
called() { grep -qF -- "$1" "$SCEN/calls"; }
count_call() { grep -cF -- "$1" "$SCEN/calls"; }

# Run the rail under a hard wall-clock watchdog and report its exit status.
#
# This exists because the wait bound can fail by HANGING rather than by
# returning: `--poll 0` makes a nominal poll-count bound unreachable (#1395 item
# 1), so a guard for that class must be able to kill the rail it is guarding.
# macOS has no `timeout`, hence the explicit poll-and-kill. 124 = the watchdog
# fired, i.e. the rail was still running past the limit.
#
# The rail is launched through `rail_exec` directly (NOT `( run_rail ... ) &`) so
# that `$!` is the RAIL: killing a wrapper subshell would leave the rail
# orphaned, and an orphan on the wait bound spins forever.
run_rail_watchdog() { # <limit-secs> <extra args...>
  local limit="$1"; shift
  rail_exec "$@" >"$SCEN/out" 2>"$SCEN/err" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  return $?
}

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

# ═══ 7b. the wait bound is a CLOCK, not a poll count (#1395 item 1) ══
echo "── 7b. the wait bound holds even when --poll 0 makes a poll-count bound inert"
new_scen pending-poll0
printf '3\n' > "$SCEN/pending"
# A permanently-pending check plus `--poll 0 --wait-timeout 2`. Under a
# nominal-poll-count bound, `elapsed` advances by 0 every iteration, so the
# documented bound is UNREACHABLE and the rail loops forever holding the PR's
# lock. The watchdog is what makes the regression a failure rather than a hang.
run_rail_watchdog 30 42 --repo "$REPO" --poll 0 --wait-timeout 2
rc=$?
if [ "$rc" -eq 124 ]; then
  fail "the rail HUNG: --poll 0 made the wait bound unreachable (the #1395 item-1 defect)"
elif [ "$rc" -eq 1 ]; then
  pass "stops on wait expiry (rc 1) — the bound is wall-clock, so --poll 0 cannot defeat it"
else
  fail "expected rc 1 (bounded stop), got $rc"
fi
called "record-review" && fail "recorded without terminal checks" || pass "no record before terminal checks"
called "admin-merge" && fail "landed without terminal checks" || pass "no land before terminal checks"
grep -q "not terminal" "$SCEN/err" && pass "the refusal names the wait" || fail "the refusal does not name the wait"

# ═══ 7c. an unrepresentable wait bound is refused, not silently inert ════
echo "── 7c. an oversized --wait-timeout is refused instead of disabling the bound"
new_scen pending-huge-timeout
printf '3\n' > "$SCEN/pending"
# `[ "$elapsed" -ge "$WAIT_TIMEOUT" ]` compares machine integers. A literal too
# wide for that comparison makes the `[` ERROR, and a failing `[` is FALSE — so
# before the cap this value left the bound silently OFF and the rail looped
# forever holding the PR's lock: the #1395 item-1 hang by a second door.
# Refusal must be immediate (rc 2). The watchdog is what turns a regression back
# into a HANG into a FAILED TEST.
run_rail_watchdog 30 42 --repo "$REPO" --poll 0 --wait-timeout 99999999999999999999999999
rc=$?
if [ "$rc" -eq 124 ]; then
  fail "the rail HUNG: an oversized --wait-timeout silently disabled the bound"
elif [ "$rc" -eq 2 ]; then
  pass "refuses an unrepresentable --wait-timeout (rc 2) instead of looping"
else
  fail "expected rc 2 (refused), got $rc"
fi
called "record-review" && fail "recorded despite a refused bound" || pass "no record"
called "admin-merge" && fail "landed despite a refused bound" || pass "no land"

# ═══ 7d. the bound is not overshot by the poll interval ═════════════
echo "── 7d. --poll cannot push the stop past --wait-timeout"
new_scen pending-overshoot
printf '3\n' > "$SCEN/pending"
# The bound is tested BEFORE the sleep, so an unclamped `sleep "$POLL"` lets the
# rail outlive its documented bound by up to a whole poll interval — measured on
# the revision before the clamp: `--wait-timeout 2 --poll 8` ran 10 s wall while
# printing "waiting (≤2s)". A watchdog at 6 s separates the clamped stop (~2 s)
# from the unclamped one (~8 s), and turns the regression into a FAILED TEST.
run_rail_watchdog 6 42 --repo "$REPO" --poll 8 --wait-timeout 2
rc=$?
if [ "$rc" -eq 124 ]; then
  fail "the rail overshot its 2s bound — --poll 8 pushed the stop past the bound"
elif [ "$rc" -eq 1 ]; then
  pass "stops at the bound, not a full poll interval later (rc 1)"
else
  fail "expected rc 1 (bounded stop), got $rc"
fi
grep -q "not terminal" "$SCEN/err" && pass "the refusal names the wait" || fail "the refusal does not name the wait"

# ═══ 7e. an oversized poll interval is refused ═════════════════
echo "── 7e. an oversized --poll is refused (it multiplies the count-bounded waits)"
new_scen pending-huge-poll
printf '3\n' > "$SCEN/pending"
# Two other waits in the rail are bounded by an ITERATION COUNT (5 polls for a
# lazy merge state, 20 for the async ref update), so an unbounded interval turns a
# "bounded" poll into a rail that outlives the run holding the lock — /bin/sleep
# ACCEPTS 999999999 (~31 years), so this is a real interval and not one the sleep
# itself rejects. `wait_terminal` is separately clamped, so what this test pins is
# the REFUSAL (rc 2); the watchdog is a safety net that turns a hang into a FAIL.
run_rail_watchdog 30 42 --repo "$REPO" --poll 999999999 --wait-timeout 2
rc=$?
if [ "$rc" -eq 124 ]; then
  fail "the rail HUNG: an oversized --poll made a sleep outlast every bound"
elif [ "$rc" -eq 2 ]; then
  pass "refuses an oversized --poll (rc 2)"
else
  fail "expected rc 2 (refused), got $rc"
fi

# ═══ 7f. the wait bound is compared and subtracted in the SAME base ═════
echo "── 7f. a leading-zero --wait-timeout cannot silently abort the wait"
new_scen pending-octal-bound
printf '3\n' > "$SCEN/pending"
# The validator and `[ "$elapsed" -ge "$WAIT_TIMEOUT" ]` both read a leading zero
# as DECIMAL, but bare `$(( WAIT_TIMEOUT - elapsed ))` reads it as OCTAL — and `08`
# is not a valid octal literal, so the arithmetic ERROR unwound the loop silently
# (rc 1, NO stop line) after step [1/4] had already moved the head and staled the
# record. `10#` pins base 10. The assertion is the STOP LINE, because both the bug
# and the fix exit non-zero: rc alone cannot tell them apart.
run_rail_watchdog 30 42 --repo "$REPO" --poll 0 --wait-timeout 08
rc=$?
if [ "$rc" -eq 124 ]; then
  fail "the rail HUNG on a leading-zero --wait-timeout"
elif grep -q "not terminal" "$SCEN/err"; then
  pass "stops on the wait bound and names it (same base, rc $rc)"
elif grep -q "value too great for base" "$SCEN/err"; then
  fail "the arithmetic read 08 as octal and aborted silently (no stop, no record)"
else
  fail "expected a bounded stop naming the wait, got rc $rc"
fi

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

# ═══ 9b. B13 — a BLOCKED, MEASURABLY-behind PR is updated ═══════════════
# The deadlock: a branch more than the drift-guard's 20 commits behind main has
# its drift-guard check FAIL, so GitHub reports `BLOCKED`, not `BEHIND` — and an
# update predicate keyed on the enum skipped the very update that would clear it
# (tortoise #6210 behind 39, #6169 behind 42). The rail must MEASURE the distance
# and update when it is non-zero, so the behind PR REACHES the B5 presence check.
echo "── 9b. B13 — mergeStateStatus=BLOCKED with a measured lag is updated"
new_scen blockedbehind
printf 'BLOCKED\n' > "$SCEN/state"
printf '39\n' > "$SCEN/behind"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "the unit completes (rc 0)" || fail "expected rc 0, got $rc ($(tail -1 "$SCEN/err"))"
called "pr update-branch 42" && pass "B13: a BLOCKED, 39-behind PR was updated (the deadlock is closed)" \
  || fail "B13: BLOCKED still skipped the update — the deadlock is intact"
called "admin-merge 42" && pass "the unit landed" || fail "did not land"

# ═══ 9c. B13 — a measured distance of 0 keeps the no-op under BLOCKED ═══
# The other direction: the measurement must not become an excuse to refresh
# everything. A BLOCKED head GitHub already reports as level with its base is a
# genuine no-op, and re-cutting it would spend the attestation for nothing.
echo "── 9c. B13 — a measured distance of 0 keeps the no-op even under BLOCKED"
new_scen blockedclean
printf 'BLOCKED\n' > "$SCEN/state"
printf '0\n' > "$SCEN/behind"
printf '%s\n' "$HEAD_NEW" > "$SCEN/head"
printf '{"pr":42,"head_sha":"%s","verdict":"clean","repo":"%s"}\n' "$HEAD_NEW" "$REPO" \
  > "$SCEN/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "completes (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" && fail "updated despite a measured distance of 0" || pass "measured 0 → no update"
called "admin-merge 42" && pass "landed directly (fresh head)" || fail "did not land"

# ═══ 9d. B13 — an unmeasurable BLOCKED state fails closed ═════════════
# An unreadable distance is not proof the head is current. `CLEAN` keeps its
# no-op, but a state GitHub calls blocked must never be read as up to date.
echo "── 9d. B13 — an unreadable distance under BLOCKED stops, not \"up to date\""
new_scen blockedunmeasured
printf 'BLOCKED\n' > "$SCEN/state"
: > "$SCEN/behind"   # the compare read yields nothing usable (empty distance)
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "stopped (rc 1) — did not certify an unmeasured base relation" || fail "expected rc 1, got $rc"
called "pr update-branch" && fail "updated on an unmeasured distance" || pass "no update on an unmeasured distance"
called "admin-merge" && fail "landed on an unmeasured base relation (B13 fail-open)" || pass "did NOT land unmeasured"
grep -q "could not measure the head/base divergence" "$SCEN/err" && pass "the stop names the unmeasured divergence" || fail "the stop does not name the unmeasured divergence"

# ═══ 10. the merge is never hand-rolled, and the rail never reads protection ═
echo "── 10. the merge is never hand-rolled; the protection read is DECLARED, LIVE and NARROW (#1565)"
new_scen norewrite
for s in "$TMP/scen-happy" "$TMP/scen-fresh" "$TMP/scen-dryrun"; do
  grep -qE '(^|[[:space:]])pr[[:space:]]+merge([[:space:]]|$)' "$s/calls" \
    && fail "a raw \`gh pr merge\` was issued from $(basename "$s")" \
    || pass "no raw \`gh pr merge\` in $(basename "$s")"
  # #1565 NARROWED this pin rather than deleting it. The rail's protection
  # dependency is now DECLARED, LIVE and NARROW, so the property to pin is no
  # longer "never reads protection" but (a) below, plus the two post-loop checks.
  # STRENGTHENED after review of #1565: the first cut allowed ANY field, ANY shape
  # and ANY number of reads at the declared endpoint, so a new undeclared protection
  # read could ship green — the very thing this pin exists to stop. The declaration is
  # "ONE positive read of `strict` per invocation", so pin the FIELD, the SHAPE and
  # the COUNT, not merely the endpoint.
  # RESIDUAL (documented, deliberately not fixed): this greps the lowercase REST
  # endpoint, so a differently-named route to the same datum (e.g. the GraphQL
  # `branchProtectionRules`) would evade it — exactly as it evaded the pin before this
  # change. Today the rail reads REST, so the pin covers every read that exists; a
  # future GraphQL read must extend this pin with it.
  if grep -E 'protection' "$s/calls" | grep -vE '/branches/[^/]+/protection[[:space:]]+--jq \.required_status_checks\.strict$' | grep -q .; then
    fail "$(basename "$s") read a protection setting other than the declared \`strict\` field read"
  else
    pass "$(basename "$s") read no undeclared protection setting (field and shape pinned)"
  fi
  n_reads="$(grep -cE '/branches/[^/]+/protection' "$s/calls")"
  [ "$n_reads" -le 1 ] \
    && pass "$(basename "$s") read protection at most once ($n_reads)" \
    || fail "$(basename "$s") read protection $n_reads times (the declaration says at most one)"
done

# (b) A CLEAN PR (no BEHIND decision point) must read NO protection at all. This is
# the owner's explicit constraint on #1565: read `strict` LIVE per invocation, never
# once-and-cached — a cached belief about branch protection cannot disagree with
# GitHub, it can only be silently wrong. A global/startup read would show up here.
grep -qE 'protection' "$TMP/scen-fresh/calls" \
  && fail "scen-fresh (CLEAN) read protection — the read is not confined to the BEHIND decision point (cached/global read)" \
  || pass "scen-fresh (CLEAN) reads no protection (per-decision, not cached)"
# (c) FAIL-CLOSED DIRECTION: scen-happy's protection fixture is ABSENT, i.e. the
# read came back unreadable (the real 404/403 shape). The refresh must still happen.
grep -qF -- 'pr update-branch' "$TMP/scen-happy/calls" \
  && pass "scen-happy (protection UNREADABLE) still refreshed — the gate fails CLOSED" \
  || fail "scen-happy did not refresh with an unreadable protection (fail-OPEN)"

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

# ═══ 17l. B11b — an ORPHANED holder that stopped beating is reclaimed ═══
# #1395 item 1's SECOND half, which the fix for item 1 did not address: the
# reclaim required a DEAD pid, so a rail that outlived its parent and stopped
# making progress held the PR's lock forever. Live specimen 2026-10-08 —
# tortoise#7653, 3h51m against this script's own 90-minute bound, 0.16s of CPU
# unchanged across a 45s sample, blocking a fully-green CLEAN PR.
make_orphan() { # -> pid of a process reparented to 1 (its parent has exited)
  local p k=0
  p="$(sh -c 'nohup sleep 300 >/dev/null 2>&1 & echo $!')"
  while [ "$k" -lt 15 ]; do
    [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "1" ] && break
    k=$((k + 1)); sleep 0.2
  done
  printf '%s' "$p"
}
echo "── 17l. an orphaned holder with a STALE heartbeat IS reclaimed (B11b)"
new_scen abandonedlock
LOCK4="$SCEN/home/.pi/agent/locks/atomic-land-daniel-ospina-agent-infra-42.lock"
mkdir -p "$LOCK4"
ORPHAN_PID="$(make_orphan)"
[ "$(ps -o ppid= -p "$ORPHAN_PID" 2>/dev/null | tr -d ' ')" = "1" ] \
  && pass "fixture: the holder is genuinely orphaned (ppid 1)" \
  || fail "fixture is not orphaned — this case would be vacuous"
printf '%s\n' "$ORPHAN_PID" > "$LOCK4/pid"
# A heartbeat that has gone stale. Backdated rather than slept through, so the
# case does not depend on a timing threshold to be meaningful.
: > "$LOCK4/heartbeat"
touch -t 202001010000 "$LOCK4/heartbeat" 2>/dev/null || true
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "reclaimed and completed (rc 0)" || fail "expected rc 0, got $rc ($(tail -1 "$SCEN/err"))"
called "admin-merge" && pass "the unit landed after reclaiming an abandoned lock" || fail "did not proceed after reclaiming an abandoned lock"
grep -qi "RECLAIMING an abandoned" "$SCEN/err" && pass "the reclaim is announced, not silent" || fail "the reclaim was silent — a stolen lock must never be quiet"
kill -9 "$ORPHAN_PID" 2>/dev/null
rm -rf "$LOCK4"

# ═══ 17m. B11b — the HEARTBEAT is load-bearing ═══════════════════════════
# An orphan whose heartbeat is FRESH is a rail still working: it beats from its
# own poll loop, and this is the pin for that condition. Dropping the staleness
# requirement would steal from it — the B11 interleave the lock exists to
# prevent. (This is the case the first attempt at this change could not write:
# it sampled CPU, and a working rail's CPU is FLAT between 30s polls.)
echo "── 17m. an orphaned holder with a FRESH heartbeat refuses (heartbeat is load-bearing)"
new_scen freshbeatlock
LOCK5="$SCEN/home/.pi/agent/locks/atomic-land-daniel-ospina-agent-infra-42.lock"
mkdir -p "$LOCK5"
ORPHAN2="$(make_orphan)"
printf '%s\n' "$ORPHAN2" > "$LOCK5/pid"
: > "$LOCK5/heartbeat"                       # fresh: just beaten, like a working rail
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "reclaimed a lock from a holder that was still beating (B11 fail-open)" || pass "did NOT reclaim a beating holder's lock"
grep -qi "already running" "$SCEN/err" && pass "the refusal names the concurrent rail" || fail "the refusal does not name the concurrent rail"
kill -9 "$ORPHAN2" 2>/dev/null
rm -rf "$LOCK5"

# ═══ 17n. B11b — a MISSING heartbeat is LIVE, not stale ══════════════════
# The lock directory is created before the first beat is written, so a rail in
# that window has no heartbeat file. Reading "no file" as "stale" would reclaim a
# lock that was created milliseconds ago — the same TOCTOU as 17c, one field
# over. Older-format locks land here too.
echo "── 17n. an orphaned lock with NO heartbeat file refuses (missing = LIVE)"
new_scen noheartbeatlock
LOCK6="$SCEN/home/.pi/agent/locks/atomic-land-daniel-ospina-agent-infra-42.lock"
mkdir -p "$LOCK6"
ORPHAN3="$(make_orphan)"
printf '%s\n' "$ORPHAN3" > "$LOCK6/pid"
# deliberately NO heartbeat file, and a threshold of 0 so ONLY the missing-file
# guard can refuse this — otherwise the case would pass for the wrong reason.
export ATOMIC_LAND_LOCK_STALE_AFTER=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
unset ATOMIC_LAND_LOCK_STALE_AFTER
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "reclaimed a lock that had published no heartbeat yet (B11 fail-open)" || pass "did NOT reclaim an unheartbeated lock"
grep -qi "already running" "$SCEN/err" && pass "the refusal names the concurrent rail" || fail "the refusal does not name the concurrent rail"
kill -9 "$ORPHAN3" 2>/dev/null
rm -rf "$LOCK6"

# ═══ 17o. B11b — the ORPHAN condition is load-bearing ════════════════════
# A lock whose holder is LIVE and whose PARENT is alive is not abandoned, even
# with a stale heartbeat: something is still waiting for its result, so it may be
# in a long non-polling phase. Dropping the ppid condition would steal it. This
# is the conservative direction, and it is the pin for that condition.
echo "── 17o. a holder with a LIVING parent and a stale heartbeat refuses (ppid is load-bearing)"
new_scen nonorphanlock
LOCK7="$SCEN/home/.pi/agent/locks/atomic-land-daniel-ospina-agent-infra-42.lock"
mkdir -p "$LOCK7"
sleep 300 &
HOLDER=$!
printf '%s\n' "$HOLDER" > "$LOCK7/pid"
[ "$(ps -o ppid= -p "$HOLDER" 2>/dev/null | tr -d ' ')" != "1" ] \
  && pass "fixture: the holder is live and NOT orphaned" \
  || fail "fixture is orphaned — this case would be vacuous"
: > "$LOCK7/heartbeat"
touch -t 202001010000 "$LOCK7/heartbeat" 2>/dev/null || true   # stale, so ONLY ppid can refuse
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 1 ] && pass "refused (rc 1)" || fail "expected rc 1, got $rc"
called "admin-merge" && fail "reclaimed a lock whose holder still has a living parent (B11 fail-open)" || pass "did NOT reclaim a lock with a live parent"
grep -qi "already running" "$SCEN/err" && pass "the refusal names the concurrent rail" || fail "the refusal does not name the concurrent rail"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true
rm -rf "$LOCK7"

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

# 17k. the check-runs read spans PAGES — a partial page is not a verdict.
# Measured 2026-09-29: a real head carried 47 check-runs and the bare endpoint
# returned 30, so the rail was answering "are the checks terminal" from a
# truncated surface. The dangerous direction is a FALSE TERMINAL: pending checks
# beyond page 1 read as zero and are handed to the land step.
echo "── 17k. multi-page check-runs: the pages are summed, not truncated"
new_scen crpages
printf '0\n3\n' > "$SCEN/pending"   # page 1: none pending · page 2: three
printf '5\n2\n' > "$SCEN/completed"
run_rail 42 --repo "$REPO" --poll 0 --wait-timeout 0
rc=$?
called "per_page=100" \
  && pass "reads check-runs with per_page=100 — not the default 30-item page" \
  || fail "check-runs read without per_page (the default page was 30 of 47 measured)"
[ "$rc" -eq 1 ] && pass "refused (rc 1) — page 2's pending checks were COUNTED" \
               || fail "expected rc 1, got $rc — page 2's 3 pending checks were invisible (false terminal)"
grep -q "not terminal" "$SCEN/err" \
  && pass "the refusal names the wait" \
  || fail "the refusal does not name the wait"
called "admin-merge 42" && fail "LANDED on a truncated read" || pass "did not land"

# ═══ 17g. #1565 — the base-drift refresh gate (read `strict` LIVE, fail closed) ═
# The step-1 refresh is only worth its cost when something REQUIRES an up-to-date
# branch. Its cost is measured: the head move invalidates the head-bound review
# record (B5), forces a full CI run at the new head, and then makes the rail wait up
# to 5400s for those checks to go terminal — while `strict: false` means the pin buys
# no mergeability at all. So the rail reads `strict` LIVE and, when it is positively
# false and the PR is positively mergeable, skips the refresh and lands at the head
# it already has (the record for which was never invalidated).
echo "── 17g-A. strict=false live + mergeable ⇒ the refresh is SKIPPED and it lands at the EXISTING head"
new_scen skipbehind
printf 'BEHIND\n' > "$SCEN/state"
printf 'false\n' > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
grep -qE '/branches/[^/]+/protection' "$SCEN/calls" \
  && pass "read \`strict\` LIVE from branch protection" \
  || fail "did not read strict (the gate cannot have fired)"
called "pr update-branch" \
  && fail "REFRESHED a mergeable PR under strict=false — this is the #1565 defect" \
  || pass "did NOT refresh (so the record at this head survives)"
[ "$(cat "$SCEN/head")" = "$HEAD_OLD" ] \
  && pass "the head was left where it was (no invalidation, no CI re-run, no 5400s wait)" \
  || fail "the head moved"
called "record-review" \
  && fail "re-recorded after a skip (the head did not move — that would dilute the evidence)" \
  || pass "no re-record: the existing record stayed valid"
called "admin-merge 42" && pass "landed at the EXISTING head" || fail "did not land"
grep -q "SKIPPING the refresh" "$SCEN/out" \
  && pass "the skip is named in the log, with its reason (auditable, not silent)" \
  || fail "the skip is not named in the log"

# DIRECTION B — every case that genuinely needs the refresh must STILL refresh.
echo "── 17g-B1. strict=true live ⇒ the refresh STILL HAPPENS (#1533: a required up-to-date head)"
new_scen stricttrue
printf 'BEHIND\n' > "$SCEN/state"
printf 'true\n' > "$SCEN/strict"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (strict=true still requires the head to be up to date)" \
  || fail "did NOT refresh under strict=true"

echo "── 17g-B2. strict=false live but NOT mergeable ⇒ the refresh STILL HAPPENS (fail-closed)"
new_scen unmergeable
printf 'BEHIND\n' > "$SCEN/state"
printf 'false\n' > "$SCEN/strict"
printf 'CONFLICTING\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (the PR is not positively mergeable)" \
  || fail "did NOT refresh an unmergeable PR under strict=false (fail-OPEN)"
grep -q "not positively mergeable" "$SCEN/out" \
  && pass "the refresh names the fail-closed reason" \
  || fail "the fail-closed reason is not named"

echo "── 17g-B3. protection UNREADABLE ⇒ the refresh STILL HAPPENS (fail-closed)"
new_scen strictunreadable
printf 'BEHIND\n' > "$SCEN/state"
# NO $SCEN/strict fixture: the read 404s/403s, exactly as it does when protection is
# unconfigured or the token has no admin on the repo.
#
# ⛔ THIS FIXTURE IS LOAD-BEARING FOR MUTATION B19 — do not remove it. With the
# `mergeable` fixture ABSENT, the fake answers `UNKNOWN` (the fail-closed default), so a
# rail that wrongly treated an unreadable `strict` as `false` would STILL not skip — and
# B19 would silently stop reddening. MEASURED in CI (the `admin-merge` job): B19 reported
# "did NOT redden the suite" for exactly this reason, because the fail-closed default was
# introduced by the round-2 review and B19 was last verified BEFORE it. Pinning
# `mergeable` to a mergeable token makes the `strict` read the ONLY thing that can decide
# this scenario — which is what B3 claims to test and what B19 claims to cover.
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed with an unreadable protection read" \
  || fail "did NOT refresh (fail-OPEN)"

echo "── 17g-B4. mergeable=UNKNOWN (GitHub computes it lazily) ⇒ the refresh STILL HAPPENS"
new_scen mergeunknown
printf 'BEHIND\n' > "$SCEN/state"
printf 'false\n' > "$SCEN/strict"
printf 'UNKNOWN\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (UNKNOWN is not a positive true)" \
  || fail "did NOT refresh on mergeable=UNKNOWN (fail-OPEN)"
# Contract pin (the #1565 review P0): the tokens the rail maps must be the CLI's enum
# tokens. Scenario A exercises MERGEABLE, so a predicate that only accepted `true`
# fails there; this states the contract once more in its own right.
grep -q 'MERGEABLE' "$RAIL" && grep -q 'CONFLICTING' "$RAIL" \
  && pass "the mergeable mapping names the CLI's enum tokens (MERGEABLE/CONFLICTING)" \
  || fail "the mergeable mapping does not name the CLI's enum tokens"

echo "── 17g-C. ATOMIC_LAND_REFRESH_ALWAYS=1 restores the unconditional refresh"
new_scen refreshalways
printf 'BEHIND\n' > "$SCEN/state"
printf 'false\n' > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
ATOMIC_LAND_REFRESH_ALWAYS=1 run_rail 42 --repo "$REPO" --poll 0
unset ATOMIC_LAND_REFRESH_ALWAYS
called "pr update-branch" \
  && pass "refreshed despite strict=false (the fail-safe restore works)" \
  || fail "the restore did not refresh"
grep -qE '/branches/[^/]+/protection' "$SCEN/calls" \
  && fail "read protection although the restore short-circuits it" \
  || pass "no protection read when the restore is set (the old behaviour is intact)"

# ═══ 17g-D. #7230 — the drift trigger must NOT pre-empt CLEAN ═════════════
# The defect: `mergeStateStatus=CLEAN` + a head that is behind the base went down the
# BASE-DRIFT arm, which fires BEFORE the `elif CLEAN` no-op — so the one state that is
# already landable was the one state guaranteed to be refreshed. The head moved, the
# head-bound record died at step 3 (#1575 clause E, correctly), and the rail could
# never land the PR. The live repro is #7462 (head `b6bbd415e131…`, 1 commit behind,
# CLEAN, strict=false): this scenario is that read, reconstructed.
echo "── 17g-D1. CLEAN + behind>0 + strict=false + mergeable ⇒ the head is KEPT and it lands"
new_scen cleandrift
printf 'CLEAN\n'    > "$SCEN/state"
printf '1\n'        > "$SCEN/behind"
printf 'false\n'    > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && fail "refreshed a CLEAN, mergeable PR under strict=false — the #7230 defect (head moved for nothing, record invalidated)" \
  || pass "did NOT refresh (the drift trigger no longer pre-empts CLEAN)"
[ "$(cat "$SCEN/head")" = "$HEAD_OLD" ] \
  && pass "the head was left where it was — the artifact this fix exists to produce" \
  || fail "the head moved"
called "record-review" \
  && fail "re-recorded after a skip (the head did not move)" \
  || pass "no re-record: the record at this head stayed valid"
called "admin-merge 42" && pass "landed at the EXISTING head" || fail "did not land"
grep -q "SKIPPING the refresh" "$SCEN/out" \
  && pass "the skip is named in the log, with its reason" \
  || fail "the skip is not named in the log"

# ── DIRECTION B — every CLEAN case that still NEEDS the refresh must refresh ────
echo "── 17g-D2. CLEAN + behind>0 + strict=true ⇒ the refresh STILL HAPPENS"
new_scen cleandriftstrict
printf 'CLEAN\n'     > "$SCEN/state"
printf '3\n'         > "$SCEN/behind"
printf 'true\n'      > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (strict=true requires an up-to-date head, whatever the merge state)" \
  || fail "did NOT refresh under strict=true — the arm is over-broad"

echo "── 17g-D3. CLEAN + behind>0 + protection UNREADABLE ⇒ the refresh STILL HAPPENS (fail-closed)"
new_scen cleandriftunreadable
printf 'CLEAN\n'     > "$SCEN/state"
printf '1\n'         > "$SCEN/behind"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
# NO $SCEN/strict fixture: 404/403, exactly as when protection is unconfigured or the
# token lacks admin. An unreadable `strict` must never be read as `false`.
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed with an unreadable protection read (fail-closed direction intact)" \
  || fail "did NOT refresh — the CLEAN arm made the `strict` read fail OPEN"

echo "── 17g-D4. CLEAN + behind>0 + strict=false but NOT mergeable ⇒ the refresh STILL HAPPENS"
new_scen cleandriftunmergeable
printf 'CLEAN\n'       > "$SCEN/state"
printf '1\n'           > "$SCEN/behind"
printf 'false\n'       > "$SCEN/strict"
printf 'CONFLICTING\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (the PR is not positively mergeable)" \
  || fail "did NOT refresh a non-mergeable PR under strict=false (fail-OPEN)"

# ── THE PRESERVED CASE — the CLEAN arm must NOT swallow #1533 ──────────────────
echo "── 17g-D5. BLOCKED + measured-behind + strict=false ⇒ the refresh STILL HAPPENS (#1533 preserved)"
new_scen blockeddriftstrictfalse
printf 'BLOCKED\n'   > "$SCEN/state"
printf '39\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch 42" \
  && pass "refreshed (a BLOCKED branch's drift red can only clear with an update — #1533)" \
  || fail "the CLEAN arm swallowed #1533: a BLOCKED, 39-behind branch was skipped"

echo "── 17g-D6. UNSTABLE + behind>0 + strict=false + mergeable ⇒ the head is ALSO kept"
# `UNSTABLE` is the second landable state: the REQUIRED checks passed and only
# NON-required ones fail or pend, so GitHub reports it mergeable and `strict: false`
# does not require the head to close the distance. Holding only `CLEAN` would have
# left this population with the same #7230 non-termination.
new_scen unstabledrift
printf 'UNSTABLE\n'  > "$SCEN/state"
printf '4\n'         > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && fail "refreshed a landable UNSTABLE head on base drift — the #7230 non-termination, one state over" \
  || pass "did NOT refresh (UNSTABLE is held with CLEAN)"
[ "$(cat "$SCEN/head")" = "$HEAD_OLD" ] \
  && pass "the head was left where it was" \
  || fail "the head moved"

# ── THE FAIL-SAFE — the documented override must reach THIS arm too ──────────
echo "── 17g-D7. ATOMIC_LAND_REFRESH_ALWAYS=1 forces the refresh from the CLEAN arm as well"
# Without this, the one documented way to disable an over-eager skip would silently
# no-op for exactly the state this fix gates — an un-disableable misfire.
new_scen cleandriftalways
printf 'CLEAN\n'     > "$SCEN/state"
printf '1\n'         > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_RECORD_LOG=1
ATOMIC_LAND_REFRESH_ALWAYS=1 run_rail 42 --repo "$REPO" --poll 0
unset ATOMIC_LAND_REFRESH_ALWAYS
called "pr update-branch" \
  && pass "refreshed despite the landable state (the fail-safe reaches the drift arm)" \
  || fail "the fail-safe did NOT restore the refresh — the skip is un-disableable"

# ═══ 18. mutation coverage for the declared threat surface ═══════════════
# The adversarial bound is the DECLARED surface, not reviewer exhaustion: every
# class B1-B12 must be covered by a test that FAILS against the revision before
# its fix. This section mutates the rail and asserts the suite reddens. A mutation
# that leaves the suite green means the class is NOT covered.
if [ "${ATOMIC_LAND_MUTATIONS:-1}" != 0 ]; then
  echo "── 18. mutation coverage — each declared bypass class must be caught"
  MUT="$TMP/mut"; mkdir -p "$MUT"
  # Two perl traps have cost this harness real coverage (all four instances fixed
  # here, found by a fresh review of this file): (1) `$` is NOT literal in a perl
  # REPLACEMENT — `"$GH"` becomes `""` unless it is spelled `\044GH`, silently
  # emptying the injected command; (2) `||` in a perl PATTERN is alternation with
  # an EMPTY branch, so it matches at OFFSET 0 and corrupts the file instead of
  # replacing the target guard — it must be spelled `\|\|`. The `bash -n` gate
  # below makes trap (2) LOUD. It CANNOT catch trap (1): an emptied replacement is
  # still perfectly valid bash, so it reddens for the WRONG reason while the
  # harness still prints "class covered". Trap (1) is caught only by reading the
  # diff, which is why every expression here is hand-audited.
  mutate_and_expect_fail() { # <name> <perl-expr>
    local name="$1"
    local expr="$2"
    local src="$MUT/$name.sh"
    cp "$RAIL" "$src"
    if ! perl -0pi -e "$expr" "$src" 2>/dev/null; then fail "mutation $name: perl failed"; return; fi
    if cmp -s "$src" "$RAIL"; then fail "mutation $name reddened nothing — the mutation did not apply"; return; fi
    # A mutation that CORRUPTS the file "reddens" the suite too — every scenario
    # fails because the rail cannot be parsed — which is a FALSE "class covered"
    # for the guard it claims. `cmp` cannot tell corruption from mutation, so the
    # result must still PARSE. This catches the `||`-in-a-pattern trap only; it
    # does NOT catch an emptied-`$` replacement, which still parses and still
    # reddens for the wrong reason (see the traps note above).
    if ! bash -n "$src" 2>/dev/null; then
      fail "mutation $name produced a file that does not PARSE — corrupt mutation, not coverage"
      return
    fi
    ATOMIC_LAND_MUTATIONS=0 ATOMIC_LAND_SUITE_RAIL="$src" bash "$0" >"$MUT/$name.log" 2>&1
    if [ $? -ne 0 ]; then
      pass "mutation $name reddens the suite (class covered)"
    else
      fail "mutation $name did NOT redden the suite (class NOT covered)"
    fi
  }
  # B1: pass the CURRENT head to record-review instead of the prior head
  mutate_and_expect_fail B1   's/"\$RECORD_SH" "\$PR" "\$prior"/"\044RECORD_SH" "\044PR" "\044HEAD"/'
  # B2a: drop the record precondition
  mutate_and_expect_fail B2a  's/if ! read_record; then/if false; then/'
  # B2b: accept every verdict (BOTH the pre-unit gate and the post-record re-read guard)
  mutate_and_expect_fail B2b  's/if ! verdict_accepted "\$RECORD_VERDICT"; then/if false; then/g'
  # B3: add a hand-rolled --admin merge beside the mandated rail
  mutate_and_expect_fail B3   's/bash "\$ADMIN_MERGE" "\$PR"/"\044GH" pr merge "\044PR" --admin; bash "\044ADMIN_MERGE" "\044PR"/'
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
  mutate_and_expect_fail B11b 's/if \[ -z "\$other" \] && \[ "\$age" -lt "\${ATOMIC_LAND_LOCK_GRACE:-60}" \]; then/if false; then/'
  # B11c: drop the HEARTBEAT-staleness requirement — reclaim a lock from a holder
  # that is still beating, which is the B11 interleave the lock exists to prevent
  # (17m reds).
  mutate_and_expect_fail B11c 's/\[ "\$age" -ge "\$LOCK_STALE_AFTER" \] 2>\/dev\/null \|\| return 1/true \|\| return 1/'
  # B11d: treat a MISSING heartbeat as stale — reclaim a lock created milliseconds
  # ago, in the mkdir→beat window (17n reds).
  mutate_and_expect_fail B11d 's/\[ -f "\$LOCKDIR\/heartbeat" \] \|\| return 1/true/'
  # B11e: drop the ORPHAN requirement — reclaim a lock whose holder still has a
  # living parent, so something is still waiting for its result (17o reds).
  mutate_and_expect_fail B11e 's/= "1" \] \|\| return 1/= "1" ] || true/'
  # B6: never stop on the terminal-check wait expiry
  mutate_and_expect_fail B6   's/^      stop "the checks at.*$/      return 0/m'
  # B14 (#1395 item 1): credit `elapsed` from a NOMINAL poll count instead of a
  # real clock — with `--poll 0` the bound is then unreachable and the rail hangs
  # NB: `$` is not literal in a perl replacement, so the `$(` and `${` are spelled
  # with `\044` (octal). The `${elapsed:-0}` default is belt-and-braces rather
  # than a version fix: `local started elapsed …` above already DECLARES `elapsed`,
  # and a declared-but-null name expands to 0 in arithmetic even under `set -u`
  # (measured: `f(){ local x; echo $((x + 1)); }` -> 1, whereas an UNDECLARED `x`
  # aborts with "unbound variable"). The default keeps the mutation faithful even
  # if that declaration is later narrowed, which is what makes the pre-fix
  # `elapsed=$((elapsed + POLL))` spelling reproduce its hang on every bash.
  mutate_and_expect_fail B14  's/^\s*elapsed=\$\(\( SECONDS - started \)\).*$/        elapsed=\044(( \044{elapsed:-0} + POLL ))/m'
  # B15 (#1395 item 1, second door): drop the `--wait-timeout` cap. An oversized
  # literal then reaches `[ "$elapsed" -ge "$WAIT_TIMEOUT" ]`, which ERRORS, and a
  # failing `[` is FALSE — so the bound goes silently OFF and the rail hangs. This
  # proves 7c's refusal is load-bearing rather than decorative.
  mutate_and_expect_fail B15  's/^\[ "\$WAIT_TIMEOUT" -le 86400 \].*$/true/m'
  # B16 (#1395 item 1, third door): drop the clamp on the final sleep, so the
  # rail overshoots its own bound by up to a whole poll interval (the bound is
  # tested before the sleep). 7d's 6 s watchdog then fires at 8 s.
  mutate_and_expect_fail B16  's/^    remaining=\$\(\( 10#\$WAIT_TIMEOUT - elapsed \)\)\n    if \[ "\$remaining" -gt "\$POLL" \]; then remaining="\$POLL"; fi\n    sleep "\$remaining"/    sleep "\044POLL"/m'
  # B17 (#1395 item 1, fourth door): drop the `--poll` cap, so an oversized
  # interval reaches /bin/sleep and multiplies the count-bounded waits as well.
  mutate_and_expect_fail B17  's/^\[ "\$POLL" -le 300 \].*$/true/m'
  # B18 (#1395 item 1, fifth door): drop the `10#` base pin, so bare arithmetic
  # reads a leading-zero `--wait-timeout` as OCTAL while the comparison reads it
  # as DECIMAL — and `08` is not a valid octal literal, so the arithmetic error
  # unwinds the wait loop SILENTLY. Base 10 must be stated, not assumed.
  mutate_and_expect_fail B18  's/remaining=\$\(\( 10#\$WAIT_TIMEOUT - elapsed \)\)/remaining=\044(( WAIT_TIMEOUT - elapsed ))/'
  # B19 (#1565): make the live `strict` read FAIL OPEN — an UNREADABLE protection
  # (404/403/absent) is then treated as `false` instead of unreadable, so the
  # direction-B3 scenario (unreadable ⇒ MUST refresh) skips instead. This is the true
  # fail-open: it is the fail-closed arm that the mutation removes. (The first cut of
  # this mutation targeted the `true|false` arm instead and was mislabelled — dropping
  # `false` fails CLOSED, i.e. it refreshes MORE — and its perl replacement was also
  # corrupt. Caught by review.)
  mutate_and_expect_fail B19  's/if \[ "\044strict" = false \]; then/if [ "\044strict" != true ]; then/'
  # B20 (#1565): let the skip ignore `mergeable`, so an UNMERGEABLE PR (the #1533
  # shape, which genuinely needs the refresh) is skipped instead. The direction-B2
  # scenario must redden.
  mutate_and_expect_fail B20  's/if \[ "\044mergeable" = true \]; then/if true; then/'
  # B19b/B20b (#7230): the SAME two fail-closed reads, in the base-DRIFT arm. The
  # indentation anchor is the point, not a style choice. `mutate_and_expect_fail` runs
  # `perl -0pi`, so an UNANCHORED `s///` with no `/g` replaces only the FIRST
  # occurrence in the file — and that was the BEHIND arm. When #7230 added a SECOND
  # `strict`/`mergeable` read, B19/B20 kept mutating the first one, so the new reads
  # would have shipped UNPINNED while both mutations still "reddened" via B3: the
  # change that extends the adversarial set quietly narrowed it. Anchoring each pattern
  # to its own arm is self-policing — re-indent the arm out from under the pattern and
  # nothing is replaced, so the mutated copy is byte-identical and mutate_and_expect_fail
  # reports "reddened nothing — the mutation did not apply" (run.sh:1183) LOUDLY. Note that
  # is the did-not-APPLY branch, not "did NOT redden the suite" (run.sh:1198), which is
  # taken when the mutation DID apply and the suite stayed green.
  # The arms are distinguishable by indentation alone (verified: strict at 8 vs 10
  # spaces, mergeable at 10 vs 12), and each anchored pattern matches exactly one site.
  # B19b must redden 17g-D3 (unreadable protection ⇒ refresh); B20b must redden 17g-D4
  # (strict=false but NOT mergeable ⇒ refresh). Both scenarios already pin the OTHER
  # read to a decisive fixture, so each mutation is the only thing that can decide its
  # scenario — the same trap that made B19 inert once before, avoided here.
  mutate_and_expect_fail B19b 's/^          if \[ "\044strict" = false \]; then/          if [ "\044strict" != true ]; then/m'
  mutate_and_expect_fail B20b 's/^            if \[ "\044mergeable" = true \]; then/            if true; then/m'
  # B21 (#7230): make the landable-state arm INERT — the drift trigger pre-empts it
  # again, i.e. the revision before this fix. The failure it prevents: the head of a
  # green, attested PR being moved for nothing and the record dying at step 3 (the O3
  # shape, 22 updated / 17 invalidated / 0 landed). 17g-D1 must redden.
  mutate_and_expect_fail B21  's/if \[ "\044drift_landable" = 1 \]/if false/'
  # B22 (#7230, the opposite direction): add BLOCKED to the landable set, so the arm
  # over-reaches and swallows #1533 — a BLOCKED branch's drift red can only clear with
  # an update, and skipping it re-deadlocks the >20-behind population. 17g-D5 must
  # redden.
  mutate_and_expect_fail B22  's/case "\044MERGE_STATE" in CLEAN\|UNSTABLE\)/case "\044MERGE_STATE" in CLEAN\|UNSTABLE\|BLOCKED\)/'
  # B23 (#7230): gate the landable-state arm on `CLEAN` alone, dropping UNSTABLE. The
  # failure it prevents: closing #7230 for one landable state and leaving the other's
  # population (measured at 10 heads) with the same non-termination. 17g-D6 must redden.
  mutate_and_expect_fail B23  's/in CLEAN\|UNSTABLE\) drift_landable=1/in CLEAN\) drift_landable=1/'
  # B7: make --dry-run a no-op (the inspection path starts mutating)
  mutate_and_expect_fail B7   's/--dry-run\)      DRY_RUN=1; shift ;;/--dry-run)      DRY_RUN=0; shift ;;/'
  # B8: treat every record as fresh
  mutate_and_expect_fail B8   's/if \[ "\$RECORD_HEAD" = "\$HEAD" \]; then/if true; then/'
  # B9: never re-check the head before landing
  mutate_and_expect_fail B9   's/if \[ "\$now" != "\$HEAD" \]; then/if false; then/'
  # B10a: never re-check the base BRANCH before landing
  mutate_and_expect_fail B10a 's/if \[ "\$now_base" != "\$CERT_BASE" \]; then/if false; then/'
  # B10b: never re-check the base's MERGE BASE before landing
  mutate_and_expect_fail B10b 's/if \[ -z "\$now_mb" \] \|\| \[ "\$now_mb" != "\$CERT_MB" \]; then/if false; then/'
  # B10c: never compare the record's own merge base to the live one (pre-unit)
  mutate_and_expect_fail B10c 's/if \[ -z "\$live_mb" \] \|\| \[ "\$live_mb" != "\$RECORD_MB" \]; then/if false; then/'
  # B12: never detect a concurrent base ADVANCE
  mutate_and_expect_fail B12  's/if \[ "\$now_tip" != "\$CERT_BASE_TIP" \]; then/if false; then/'
  # B12b: the CAPTURE read must fail closed — an empty capture must not silently
  # disable the pre-land comparison (the path the reviewer reproduced).
  mutate_and_expect_fail B12b 's/if \[ -z "\$CERT_BASE_TIP" \]; then/if false; then/'
  # B13: neutralise the MEASUREMENT — trust `mergeStateStatus` alone. A FAILING
  # required check masks a stale head as BLOCKED, so the measuring arm is the only
  # thing that sees the lag; with the distance always reading 0 the >20-behind PR
  # the drift-guard is blocking never gets the update that would clear it.
  mutate_and_expect_fail B13 's/behind="\$\(behind_by_of "\$BASE" "\$HEAD"\)"/behind=0/'
  # B11: never take the per-PR lock
  mutate_and_expect_fail B11  's/\[ "\$DRY_RUN" -eq 0 \] && acquire_lock//'
  # D1d (#1362): the partial-install diagnostic is not a bypass class, but it is
  # a D1 behavior the suite pins — removing its guard must redden scenario 2.
  mutate_and_expect_fail D1d  's/if \[ ! -f "\$DIFF_NORMALIZER_SH" \]; then/if false; then/'
  # D2a (2026-09-29): the check-runs read must not use the default 30-item page —
  # the terminal verdict is computed over a truncated surface otherwise.
  mutate_and_expect_fail D2a  's/\?per_page=100//'
  # D2b: --paginate emits ONE result per page; reading only the first page hides a
  # later pending check and turns it into a false terminal verdict.
  mutate_and_expect_fail D2b  's/ --paginate//g'
fi

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks atomic-land test(s) failed"
  exit 1
fi
echo "✅ all $checks atomic-land tests passed"
