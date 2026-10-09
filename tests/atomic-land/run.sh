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
    # The rail asks for the slug AND the canonical URL; the URL is what pins the
    # drift predicate's HOST (#7727), so the fixture must speak both shapes.
    case "$*" in
      *--json*url*)
        # A scenario may pin the web url the CLI reports (e.g. an IPv6-literal host).
        [ -n "${SCEN:-}" ] && [ -f "$SCEN/cwd-url" ] && { cat "$SCEN/cwd-url"; exit 0; }
        printf 'https://github.com/%s\n' "${REPO_FIXTURE:-$REPO}"; exit 0 ;;
      *) printf '%s\n' "$REPO_FIXTURE"; exit 0 ;;
    esac ;;
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

# ── fake drift predicate (#7727) ───────────────────────────────────────────
# The rail CALLS the target repo's own `tools/drift-guard.py`. A repo with no such
# tool has no drift gate, so the rail's no-gate branch keeps the #7230 skip and
# every pre-existing scenario is unaffected. These scenarios inject the predicate
# via ATOMIC_LAND_DRIFT_GUARD and model its three REAL outcomes, EXIT CODES
# INCLUDED (the real tool exits 0 green, 1 on a revert, 2 on an environment error):
#   $SCEN/drift-status = ok     ⇒ exit 0, `"status": "ok"`    (green ⇒ skip stands)
#   $SCEN/drift-status = drift  ⇒ exit 1, `"status": "drift"` (unsafe ⇒ MUST refresh)
#   the fixture ABSENT          ⇒ exit 2, no output            (unmeasurable ⇒ refresh)
# Faithful exit codes are the point: the scenario that must refresh does so on a red
# MEASUREMENT, not merely on a failing process.
DRIFT="$TMP/fake-drift-guard"
cat > "$DRIFT" <<'DRIFTEOF'
#!/usr/bin/env bash
set -uo pipefail
SCEN="${SCEN:?SCEN must be set}"
printf 'drift-guard %s\n' "$*" >> "$SCEN/drift-calls"
if [ -f "$SCEN/drift-status" ]; then
  st="$(cat "$SCEN/drift-status")"
  printf '{"status": "%s", "branch": "(detached HEAD)", "base": "origin/main"}\n' "$st"
  [ "$st" = ok ] && exit 0
  exit 1
fi
echo "drift-guard: could not fetch the base — its freshness cannot be proven" >&2
exit 2
DRIFTEOF
chmod +x "$DRIFT"

# A SECOND fixture whose EXIT CODE is DECOUPLED from its JSON status. The fixture
# above keeps them faithful (exit 0 iff status ok), which is realistic but makes
# trap 1 UNTESTABLE: a rail that reads the process exit code instead of the JSON
# `status` passes every scenario, so a regression to exit-code keying ships green.
# This fixture can CONTRADICT itself, which is the only way to pin trap 1 (#7727).
DRIFT_EXITCODE="$TMP/fake-drift-guard-decoupled"
cat > "$DRIFT_EXITCODE" <<'DRIFTEOF'
#!/usr/bin/env bash
set -uo pipefail
SCEN="${SCEN:?SCEN must be set}"
printf 'drift-guard %s\n' "$*" >> "$SCEN/drift-calls"
st="$(cat "$SCEN/drift-status")"
printf '{"status": "%s", "branch": "(detached HEAD)", "base": "origin/main"}\n' "$st"
exit "$(cat "$SCEN/drift-exit")"
DRIFTEOF
chmod +x "$DRIFT_EXITCODE"

# The DEFAULT run directory for every scenario. It must be a real git checkout whose
# `origin` carries the target slug, because the rail asserts the remote its predicate
# fetches: defaulting to the CALLER's cwd made each no-override scenario depend on
# that checkout's origin, so a fork clone false-redded for a reason unrelated to the
# code (review round 8). This one is the suite's own and hermetic.
git init -q "$TMP/default-cwd" 2>/dev/null || true
git -C "$TMP/default-cwd" remote add origin "https://github.com/$REPO.git" 2>/dev/null || true
# A readable `origin/main` WITH NO tool in it. The no-gate exception asks the BASE REF
# whether a gate exists (a stale checkout must not read "no gate" for a repo that has
# one), so the hermetic checkout needs the ref it asks for. `git init` alone leaves
# `origin/main` unborn, which the exception correctly reads as unprovable — and every
# no-override scenario would then refresh for a reason unrelated to what it tests.
printf 'x\n' > "$TMP/default-cwd/README.md"
git -C "$TMP/default-cwd" -c user.email=suite@example.invalid -c user.name=suite \
  add README.md >/dev/null 2>&1
git -C "$TMP/default-cwd" -c user.email=suite@example.invalid -c user.name=suite \
  commit -q -m init >/dev/null 2>&1
git -C "$TMP/default-cwd" update-ref refs/remotes/origin/main HEAD

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
  # #7727: the drift predicate is injected per-scenario; absent ⇒ the rail's
  # no-gate branch (no override AND no tools/drift-guard.py in this repo), which
  # keeps every pre-existing scenario's skip behaviour bit-for-bit.
  SCEN_DRIFT_CMD=
  rm -f "$SCEN/drift-status" 2>/dev/null || true
  # #7727: the cwd's repo slug. Defaults to the target repo, so the drift exception
  # applies; a scenario that sets it to ANOTHER slug models `--repo owner/name`
  # naming a different repo while the cwd holds the wrong `tools/`.
  SCEN_CWD_REPO=
  # #7727: where the rail is RUN from. Empty ⇒ $TMP/default-cwd, a HERMETIC checkout
  # whose `origin` carries the target slug (the rail asserts the remote its predicate
  # fetches). A scenario sets it to a SUBDIRECTORY of a repo whose root holds
  # `tools/drift-guard.py`, which is the only way to tell a root-anchored tool test
  # from a cwd-relative one.
  SCEN_CWD=
  # #7727: the drift threshold. 0 is the production default; a non-zero value is how
  # the "distance below the threshold" arms are reached at all.
  SCEN_DRIFT_TRIGGER=
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
  : > "$SCEN/drift-calls"
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
  # #7727: run the rail from a DETERMINISTIC directory — the suite's own hermetic
  # checkout (whose origin carries the target slug), unless the scenario names
  # another. Inheriting the caller's cwd made the identity assertions depend on
  # ambient state: launched from a checkout that HAS `tools/drift-guard.py` (tortoise,
  # the repo this rail lands) the rail ran that FOREIGN tool, and launched from a
  # clone whose origin differs it read as unidentifiable — either way every
  # no-override scenario false-redded for a reason unrelated to the code (review
  # rounds 6 and 8, both measured).
  cd "${SCEN_CWD:-$TMP/default-cwd}"
  SCEN="$SCEN" HOME="$SCEN/home" REPO_FIXTURE="${SCEN_CWD_REPO:-$REPO}" HEAD_MOVED="$HEAD_MOVED" TMPDIR="$SCEN/tmp" \
  SCEN_RECORD_RC="${SCEN_RECORD_RC:-0}" SCEN_RECORD_LOG="${SCEN_RECORD_LOG:-}" \
  SCEN_RECORD_FILE="$SCEN_RECORD_FILE" \
  SCEN_RECORD_NO_WRITE="${SCEN_RECORD_NO_WRITE:-0}" \
  SCEN_RECORD_MOVES_HEAD="${SCEN_RECORD_MOVES_HEAD:-0}" \
  SCEN_RECORD_REPOINTS_BASE="${SCEN_RECORD_REPOINTS_BASE:-0}" \
  SCEN_ADMIN_RC="${SCEN_ADMIN_RC:-0}" ATOMIC_LAND_CONFIRM_MAX="${ATOMIC_LAND_CONFIRM_MAX:-60}" \
  ATOMIC_LAND_GH="$FAKE" ATOMIC_LAND_RECORD_SH="$REC" ATOMIC_LAND_ADMIN_MERGE="$ADM" \
  ATOMIC_LAND_DRIFT_GUARD="${SCEN_DRIFT_CMD:-}" \
  ATOMIC_LAND_DRIFT_TRIGGER="${SCEN_DRIFT_TRIGGER:-0}" \
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
# printing "waiting (≤2s)". A watchdog separates the clamped stop from the
# unclamped one, and turns the regression into a FAILED TEST.
#
# The interval is deliberately WIDE (poll 60, watchdog 30, bound 2) rather than the
# original 8/6/2. The ratio is what carries the assertion — the watchdog must sit
# ABOVE a legitimate stop and BELOW a full poll interval — but the original margin
# was so thin that on a loaded host (measured: load avg 258 on 10 CPUs) a
# CLAMPED stop cost 5–7 s of wall time in subprocess overhead alone and straddled
# the 6 s watchdog, so a correct rail was killed as if it had overshot. That was a
# false red on 7 of 9 runs. Widening the interval restores the separation without
# weakening anything: an unclamped `sleep 60` is still caught, just later.
run_rail_watchdog 30 42 --repo "$REPO" --poll 60 --wait-timeout 2
rc=$?
if [ "$rc" -eq 124 ]; then
  fail "the rail overshot its 2s bound — --poll 60 pushed the stop past the bound"
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
# Anchored to the MAPPING ARMS, not to any occurrence of the token: both tokens
# ALSO appear in the comment above naming the CLI's enum, so the earlier bare
# `grep -q MERGEABLE` was satisfied by the comment alone — deleting both mapping
# arms left it green (measured, round 4). The behavioural coverage is 17g-A (a
# predicate that accepted only `true` would fail there); this only states the token
# contract, so it must read the arms themselves.
grep -qE '^[[:space:]]*MERGEABLE\)' "$RAIL" && grep -qE '^[[:space:]]*CONFLICTING\)' "$RAIL" \
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

# ═══ 17g-E. #7727 — a mergeable head is not necessarily a LANDABLE one ═════
# `mergeable` answers "no text conflict", a different question from "would the merge
# KEEP the base's content". The skip above takes the second for granted. When it is
# false the skip leaves the head permanently unlandable: the drift red cannot clear
# without a refresh, and the skip keeps refusing to do it. Live instance: PR #7703
# (CLEAN, mergeable, 14 behind) — drift-guard reported 776 lines of silent revert, a
# zero-conflict rebase made it green, and the refresh WAS the fix.
# NOTE: SCEN_DRIFT_CMD must be set AFTER each new_scen (which resets it), like every
# other per-scenario fixture here.

echo "── 17g-E1. CLEAN + behind>0 + strict=false + mergeable + drift RED ⇒ the refresh HAPPENS (#7727)"
new_scen cleandriftunsafe
SCEN_DRIFT_CMD="$DRIFT"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'drift\n'     > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0) after the refresh" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && pass "refreshed: the merge would not keep main's content, so the drift IS what blocks it" \
  || fail "SKIPPED a drift-unsafe head — the #7230 skip left it unlandable (#7703's shape)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" \
  && pass "the drift predicate was consulted at all" \
  || fail "the predicate was never called"
# The rail's stdout is the human's evidence for WHY a head moved, so the reason must
# be attributed to the branch that was actually taken. NOTE the count is not the
# assertion: the DECISION line (here) and the ACTION line at the update call are both
# `[1/4] update`, so a refresh legitimately emits two. What must never appear is the
# sibling arm's line — true of that arm, false here (mergeable IS true) — which a
# fall-through printed as well: a fresh misattribution inside the fix for one.
grep -q "drift predicate is NOT positively green" "$SCEN/out" \
  && pass "the refresh names the drift predicate as the reason" \
  || fail "the decision line does not name the drift predicate"
grep -q "not positively mergeable" "$SCEN/out" \
  && fail "the drift-red path claimed the PR was not mergeable — it IS (false attribution)" \
  || pass "and it does NOT claim the PR is unmergeable (no fall-through misattribution)"

# ── DIRECTION B — a GREEN predicate must still take the skip ─────────────
echo "── 17g-E2. …and with the predicate GREEN the head is KEPT (the #7230 fix is preserved)"
new_scen cleandriftsafe
SCEN_DRIFT_CMD="$DRIFT"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'ok\n'        > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && fail "refreshed a head whose merge WOULD keep main's content — the O3 waste (#7230)" \
  || pass "did NOT refresh (safe drift ⇒ nothing to repair)"
[ "$(cat "$SCEN/head")" = "$HEAD_OLD" ] \
  && pass "the head was left where it was" \
  || fail "the head moved for a safe drift"

# ── FAIL-CLOSED — unmeasurable must never stand in for green ─────────────
echo "── 17g-E3. …and an UNMEASURABLE predicate REFRESHES (fail-closed)"
new_scen cleandriftunmeasured
SCEN_DRIFT_CMD="$DRIFT"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
# NO $SCEN/drift-status: the fake exits 2 with no output, exactly as the real tool
# does when it cannot prove the base's freshness (#4174).
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed on an unmeasurable predicate (a possibly-stale base is never a pass)" \
  || fail "an unmeasurable predicate was read as GREEN — fail-open"

# ── THE BASE REF SHAPE — a MEASURED trap (#7727) ─────────────────────────
echo "── 17g-E4. the predicate is passed a FETCHABLE base ref (origin/<base>), not the bare branch"
# MEASURED: `--base main` exits 2 (`status: error`, "not a remote-tracking ref — the
# gate cannot prove its freshness") while `--base origin/main` measures. The rail's
# $BASE is the bare branch name, so passing it would make EVERY read an error and
# disable the skip permanently — a silent failure of this whole arm.
# Self-contained (its own scenario): it previously grepped the PREVIOUS scenario's
# log, so its result depended on E3 existing and running first (round-3 finding).
new_scen drifte4
SCEN_DRIFT_CMD="$DRIFT"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'drift\n'     > "$SCEN/drift-status"
run_rail 42 --repo "$REPO" --poll 0
grep -qF -- "origin/main" "$SCEN/drift-calls" \
  && pass "invoked with origin/main" \
  || fail "not passed a fetchable base ref (got: $(head -1 "$SCEN/drift-calls" 2>/dev/null))"
grep -qF -- "--json" "$SCEN/drift-calls" \
  && pass "invoked with --json (the JSON status, not the exit code, is the decision basis)" \
  || fail "not passed --json — the decision basis would be the tool's unspecified human output"
grep -qF -- "--head $HEAD_OLD" "$SCEN/drift-calls" \
  && pass "invoked with the head under review ($HEAD_OLD)" \
  || fail "the head under review was not passed to the predicate (got: $(head -1 "$SCEN/drift-calls" 2>/dev/null))"

# ── THE EXIT CODE IS NOT THE DECISION BASIS — trap 1, pinned in BOTH directions ──
echo "── 17g-E13. status=drift with exit 0 ⇒ REFRESH (a green must be a MEASUREMENT, not a return code)"
# The main fixture couples code to payload, so it cannot tell a JSON-keyed rail from
# an exit-code-keyed one. Trap 1 says the tool exits 1 for a revert AND for an
# unusable interpreter, so the exit code cannot be the decision — but only a fixture
# whose code CONTRADICTS its payload can prove the rail obeys that.
new_scen driftexitcode
SCEN_DRIFT_CMD="$DRIFT_EXITCODE"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'drift\n'     > "$SCEN/drift-status"
printf '0\n'         > "$SCEN/drift-exit"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed — a drift measurement was not read as green for exiting 0" \
  || fail "SKIPPED on exit 0 while the payload said status=drift (the exit-code trap, unpinned)"

echo "── 17g-E14. status=ok with exit 1 ⇒ SKIP (the same trap, the other direction)"
new_scen driftexitcode2
SCEN_DRIFT_CMD="$DRIFT_EXITCODE"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'ok\n'        > "$SCEN/drift-status"
printf '1\n'         > "$SCEN/drift-exit"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && fail "REFRESHED on a green MEASUREMENT because the process exited 1" \
  || pass "did NOT refresh (a green measurement is kept, whatever the exit code)"

# ── NO GATE — the one deliberate exception ───────────────────────────────
echo "── 17g-E5. a repo with NO drift gate keeps the skip (nothing to leave unlandable)"
new_scen cleandriftnogate
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_DRIFT_CMD=          # no override, and this repo has no tools/drift-guard.py
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && fail "refreshed although no drift gate exists to leave the head unlandable" \
  || pass "did NOT refresh (no gate ⇒ the drift is harmless by construction)"

# ── THE CWD IS NOT THE TARGET REPO — a fail-OPEN the review found ─────────
echo "── 17g-E6. a missing tool with --repo naming ANOTHER repo ⇒ REFRESH (absence proves nothing)"
# The rail never `cd`s and `--repo owner/name` is supported, so `./tools/` can belong
# to a DIFFERENT repo. Inferenceing "no gate" from its absence then skips a head whose
# target DOES have the gate — the exact unlandable-head failure #7727 exists to stop.
# The exception therefore needs positive evidence that the cwd IS the target repo.
new_scen driftwrongcwd
SCEN_CWD_REPO="daniel-ospina/some-other-repo"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_DRIFT_CMD=          # no override and no local tool: the case that used to skip
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (an unverifiable cwd is unmeasurable ⇒ fail-closed)" \
  || fail "SKIPPED on a missing tool in the WRONG repo — fail-OPEN (the review's P1)"

# ── A PRESENT TOOL IN A CHECKOUT THAT IS NOT THE TARGET — the round-4 fail-OPEN ──
echo "── 17g-E15. a PRESENT tool in a checkout that is NOT the target ⇒ REFRESH (its green is about the WRONG repo)"
# The identity test used to sit INSIDE the missing-tool branch, so when the tool WAS
# present it ran from ANY checkout and its green was attributed to the target. The
# tool measures its OWN checkout's repo (`git rev-parse --show-toplevel` +
# `origin/<base>`), so a green here is a statement about a DIFFERENT repo — the same
# unlandable-head fail-OPEN the missing-tool branch was fixed for, one branch over.
new_scen driftwrongcwdwithtool
git init -q "$TMP/e15repo"
# An origin that SATISFIES the remote assertions (slug at a boundary, same host), so
# the SCEN_CWD_REPO mismatch below is the ONLY thing that can reject this checkout.
# Without it the origin read is empty and this scenario refreshes for that reason
# instead, leaving mutation B28 (identity gate inert) undetected here (review round 9).
git -C "$TMP/e15repo" remote add origin "https://github.com/$REPO.git"
mkdir -p "$TMP/e15repo/tools" "$TMP/e15repo/sub"
cat > "$TMP/e15repo/tools/drift-guard.py" <<'E15EOF'
import json, os, pathlib, sys
scen = os.environ["SCEN"]
pathlib.Path(scen, "drift-calls").open("a").write("drift-guard " + " ".join(sys.argv[1:]) + "\n")
print(json.dumps({"status": "ok", "base": "origin/main"}))
E15EOF
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_CWD="$TMP/e15repo/sub"                    # the tool IS here, at the scratch root
SCEN_CWD_REPO="daniel-ospina/some-other-repo"  # ...but the checkout is NOT the target
SCEN_DRIFT_CMD=                                # NO override: exercise the real default path
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
SCEN_CWD=
called "pr update-branch" \
  && pass "refreshed — a green measured against ANOTHER repo is not evidence about the target" \
  || fail "SKIPPED on a green from another repo's tool (the round-4 fail-OPEN)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" 2>/dev/null \
  && fail "the predicate RAN before the identity was established — its wrong-repo green was used" \
  || pass "and it was never consulted: identity failed before any measurement"

# ── A FORK LAYOUT — `gh` and the tool DISAGREE about which repo this is ──
echo "── 17g-E16. a fork layout (origin=fork, upstream=target) ⇒ REFRESH (the tool fetches origin, not what gh resolves)"
# The tool fetches the checkout's `origin` remote. `gh repo view` resolves the "base
# repo" and PREFERS a remote named `upstream`. MEASURED on this box: with
# origin=https://github.com/daniel-ospina/agent-infra.git and
# upstream=https://github.com/daniel-ospina/tortoise.git, `gh repo view --json
# nameWithOwner -q .nameWithOwner` prints `daniel-ospina/tortoise`. So the CWD_REPO
# check passes (gh named the target) while the measurement is of the FORK — the
# round-4 fail-OPEN one layer down (review round 7).
# The fork's name is deliberately the TARGET'S plus a suffix: `owner/name-fork`
# CONTAINS `owner/name`, so a substring test passes it and the slug must be matched
# at a PATH BOUNDARY instead.
new_scen driftforklayout
git init -q "$TMP/e16repo"
mkdir -p "$TMP/e16repo/tools" "$TMP/e16repo/sub"
git -C "$TMP/e16repo" remote add origin   "https://github.com/${REPO}-fork.git"
git -C "$TMP/e16repo" remote add upstream "https://github.com/$REPO.git"
cat > "$TMP/e16repo/tools/drift-guard.py" <<'E16EOF'
import json, os, pathlib, sys
scen = os.environ["SCEN"]
pathlib.Path(scen, "drift-calls").open("a").write("drift-guard " + " ".join(sys.argv[1:]) + "\n")
print(json.dumps({"status": "ok", "base": "origin/main"}))
E16EOF
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_CWD="$TMP/e16repo/sub"
SCEN_CWD_REPO="$REPO"     # gh resolves the UPSTREAM, which IS the target, so that check passes
SCEN_DRIFT_CMD=           # NO override: exercise the real default path
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
SCEN_CWD=
called "pr update-branch" \
  && pass "refreshed — the tool fetches origin (the fork), so its green is not about the target" \
  || fail "SKIPPED on a green measured from a FORK's origin (the round-7 wrong-repo green)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" 2>/dev/null \
  && fail "the predicate was CONSULTED although the remote it fetches is not the target" \
  || pass "and it was never consulted: the remote assertion failed before any measurement"

# ── A SAME-SLUG REMOTE ON ANOTHER HOST — round 8 ──
echo "── 17g-E17. origin on a DIFFERENT host with the same owner/name ⇒ REFRESH (a remote is host+owner+name)"
# The path-boundary check pins owner/name. A remote is (host, owner, name), so a
# mirror on another host whose path still ends `owner/name` is a DIFFERENT repository;
# its green must not be attributed to the target (review round 8).
new_scen driftforeignhost
git init -q "$TMP/e17repo"
mkdir -p "$TMP/e17repo/tools" "$TMP/e17repo/sub"
git -C "$TMP/e17repo" remote add origin "https://gitlab.com/grp/$REPO.git"
cat > "$TMP/e17repo/tools/drift-guard.py" <<'E17EOF'
import json, os, pathlib, sys
scen = os.environ["SCEN"]
pathlib.Path(scen, "drift-calls").open("a").write("drift-guard " + " ".join(sys.argv[1:]) + "\n")
print(json.dumps({"status": "ok", "base": "origin/main"}))
E17EOF
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_CWD="$TMP/e17repo/sub"
SCEN_CWD_REPO="$REPO"     # gh names the target, so the slug check passes; the HOST must stop it
SCEN_DRIFT_CMD=           # NO override: exercise the real default path
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
SCEN_CWD=
called "pr update-branch" \
  && pass "refreshed — a same-slug remote on another host is a different repository" \
  || fail "SKIPPED on a green from a mirror on a FOREIGN host (the round-8 wrong-repo green)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" 2>/dev/null \
  && fail "the predicate was CONSULTED although its HOST is not the target's" \
  || pass "and it was never consulted: the host assertion failed before any measurement"

# ── AN IPv6-LITERAL HOST — round 9 ───────────────────────────────────────
echo "── 17g-E18. two IPv6-literal hosts, same owner/name ⇒ REFRESH (a colon is not always a port separator)"
# The host parser cuts at the first colon to drop `:port`. For `[2001:db8::1]` that
# colon is INSIDE the brackets, so both sides reduce to `[2001` and two DIFFERENT
# hosts compare EQUAL — the silent wrong-repo fail-OPEN, reachable whenever gh and
# origin are both IP-literal (a self-hosted GHE addressed by address). The parser
# must cut at the closing bracket instead. Reverting `remote_host_of`'s `\[*` arm to
# a first-colon cut reddens THIS scenario (and only it).
new_scen driftipv6host
git init -q "$TMP/e18repo"
mkdir -p "$TMP/e18repo/tools" "$TMP/e18repo/sub"
git -C "$TMP/e18repo" remote add origin "https://[2001:dead::9]/$REPO.git"
printf 'https://[2001:db8::1]/%s\n' "$REPO" > "$SCEN/cwd-url"
cat > "$TMP/e18repo/tools/drift-guard.py" <<'E18EOF'
import json, os, pathlib, sys
scen = os.environ["SCEN"]
pathlib.Path(scen, "drift-calls").open("a").write("drift-guard " + " ".join(sys.argv[1:]) + "\n")
print(json.dumps({"status": "ok", "base": "origin/main"}))
E18EOF
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_CWD="$TMP/e18repo/sub"
SCEN_CWD_REPO="$REPO"     # the slug passes; only the HOST separates these two
SCEN_DRIFT_CMD=           # NO override: exercise the real default path
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
SCEN_CWD=
called "pr update-branch" \
  && pass "refreshed — [2001:db8::1] and [2001:dead::9] are different hosts, not one [2001" \
  || fail "SKIPPED: two DIFFERENT IPv6 hosts collapsed to the same prefix (the round-9 fail-OPEN)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" 2>/dev/null \
  && fail "the predicate was CONSULTED although its HOST is not the target's" \
  || pass "and it was never consulted: the host assertion failed before any measurement"

# ── STALE CHECKOUT — the no-gate exception must ask the BASE REF ────────
echo "── 17g-E19. the base ref HAS the tool but this checkout does not ⇒ REFRESH (a stale tree is not evidence of no gate)"
# "No local file" is not "no gate". A checkout one commit behind the base, or a file
# deleted locally, reads "no gate" for a repo that HAS one — and that skip is
# unmeasured. The exception therefore asks `origin/<base>` (the same ref the predicate
# measures against) and takes the skip only when the ref is READABLE and lacks the
# tool. Here the ref has it and the tree does not.
new_scen driftstalegatetree
rm -rf "$TMP/e19repo"; git init -q "$TMP/e19repo"
mkdir -p "$TMP/e19repo/tools" "$TMP/e19repo/sub"
git -C "$TMP/e19repo" remote add origin "https://github.com/$REPO.git"
cat > "$TMP/e19repo/tools/drift-guard.py" <<'E19EOF'
import json
print(json.dumps({"status": "ok", "base": "origin/main"}))
E19EOF
printf 'x\n' > "$TMP/e19repo/README.md"
git -C "$TMP/e19repo" -c user.email=suite@example.invalid -c user.name=suite add -A >/dev/null 2>&1
git -C "$TMP/e19repo" -c user.email=suite@example.invalid -c user.name=suite commit -q -m init >/dev/null 2>&1
git -C "$TMP/e19repo" update-ref refs/remotes/origin/main HEAD
rm -f "$TMP/e19repo/tools/drift-guard.py"      # the base ref HAS it; this tree does not
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_CWD="$TMP/e19repo/sub"
SCEN_CWD_REPO="$REPO"     # identity and host pass; only the base-ref read separates these
SCEN_DRIFT_CMD=           # NO override: exercise the real default path
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
SCEN_CWD=
called "pr update-branch" \
  && pass "refreshed — the base ref carries a gate this checkout cannot run" \
  || fail "SKIPPED: a stale working tree read as 'the target has no drift gate'"

# ── A SCHEME-LESS ORIGIN WITH A COLON BEFORE THE `@` — round 10 ─────────
echo "── 17g-E20. scheme-less origin 'user:pw@github.com/o/n' ⇒ REFRESH (git reads the host as 'user', not github.com)"
# git's scp-like form is `[user@]host:path`, and github's own scp form is
# `git@github.com:owner/name`. Writing userinfo into THAT form gives
# `user:pw@github.com:owner/name` — which git still reads as scp-like, because no
# slash precedes the first colon, so its host is `user` and its path is
# `pw@github.com:owner/name`. The rail's first-`@` read instead named the TARGET's host
# and took the skip on a fetch that ssh's elsewhere. NOTE the colon on BOTH sides is
# what makes this shape discriminating: without the trailing colon the fallback arm
# does not match either and the authority is empty for the right reason.
new_scen driftscplikeuserinfo
git init -q "$TMP/e20repo"
mkdir -p "$TMP/e20repo/tools" "$TMP/e20repo/sub"
git -C "$TMP/e20repo" remote add origin "user:pw@github.com:$REPO"
cat > "$TMP/e20repo/tools/drift-guard.py" <<'E20EOF'
import json, os, pathlib, sys
scen = os.environ["SCEN"]
pathlib.Path(scen, "drift-calls").open("a").write("drift-guard\n")
print(json.dumps({"status": "ok", "base": "origin/main"}))
E20EOF
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_CWD="$TMP/e20repo/sub"
SCEN_CWD_REPO="$REPO"     # the slug and the naive host parse BOTH pass; git's parse disagrees
SCEN_DRIFT_CMD=           # NO override: exercise the real default path
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
SCEN_CWD=
called "pr update-branch" \
  && pass "refreshed — the remote's authority is unreadable, so its green is not about the target" \
  || fail "SKIPPED on a fetch whose host git parses as 'user', not the target (the round-10 fail-OPEN)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" 2>/dev/null \
  && fail "the predicate was CONSULTED although the authority it would fetch is unreadable" \
  || pass "and it was never consulted: the authority check failed before any measurement"

# ── THE SIBLING ARM — the same inference one arm over ─────────────────────
echo "── 17g-E7. BEHIND + behind>0 + strict=false + mergeable + drift RED ⇒ REFRESH too"
# The `BEHIND` enum routes to its own arm, which skipped on `mergeable` alone. Same
# root cause: `mergeable` answers "no text conflict", not "the merge keeps the content".
new_scen behinddriftunsafe
SCEN_DRIFT_CMD="$DRIFT"
printf 'BEHIND\n'    > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'drift\n'     > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed on a drift-red BEHIND head (the other arm consulted the predicate too)" \
  || fail "SKIPPED a drift-unsafe BEHIND head — the same inference, one arm over"

echo "── 17g-E8. …and BEHIND with a GREEN predicate still SKIPS (#1565 preserved)"
new_scen behinddriftsafe
SCEN_DRIFT_CMD="$DRIFT"
printf 'BEHIND\n'    > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'ok\n'        > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
# Assert the rail is HEALTHY, not merely quiet. Absence of an update call is
# satisfied by a rail that crashed before reaching it, so E8 would report a skip on
# a dead run — the sibling E2 (rc + head) and E5 (rc) both check this, and the
# asymmetry was the gap. A "did not refresh" verdict must mean "chose not to".
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && fail "refreshed a BEHIND head with safe drift — #1565's skip was reversed" \
  || pass "did NOT refresh (safe drift ⇒ the BEHIND skip stands)"
[ "$(cat "$SCEN/head")" = "$HEAD_OLD" ] \
  && pass "the head was left where it was" \
  || fail "the head moved for a safe drift"

# ── ROOT ANCHORING — the round-2 fail-OPEN ─────────────────────────────
echo "── 17g-E9. the tool is found from a SUBDIRECTORY: the path is anchored to the repo ROOT"
# BEHAVIOURAL, not a source-text grep. Round 3 showed a grep is satisfied by leaving
# the anchored string in a COMMENT while the code reverts to a relative path. The
# rail resolves its tool against `git rev-parse --show-toplevel`, so the only honest
# test runs the rail somewhere the repo root DIFFERS from the process cwd: a real git
# checkout whose ROOT holds tools/drift-guard.py, with the rail started in `sub/`.
# A cwd-relative test would miss the tool at the root, read "no gate", and SKIP a
# drift-red head — which is exactly what this scenario must NOT do.
new_scen driftsubdir
git init -q "$TMP/e9repo"
mkdir -p "$TMP/e9repo/tools" "$TMP/e9repo/sub"
# An `origin` remote whose URL carries the target slug: the gate now also asserts the
# remote the tool FETCHES, so a scratch repo without one reads as unidentifiable and
# refreshes before the predicate is ever consulted (see 17g-E16).
git -C "$TMP/e9repo" remote add origin "https://github.com/$REPO.git"
# The tool must be PYTHON: the default argv is `uv run python <tool>`.
cat > "$TMP/e9repo/tools/drift-guard.py" <<'E9EOF'
import json, os, pathlib, sys
scen = os.environ["SCEN"]
pathlib.Path(scen, "drift-calls").open("a").write("drift-guard " + " ".join(sys.argv[1:]) + "\n")
p = pathlib.Path(scen, "drift-status")
if not p.exists():
    print("drift-guard: no fixture", file=sys.stderr); sys.exit(2)
st = p.read_text().strip()
print(json.dumps({"status": st, "base": "origin/main"}))
sys.exit(0 if st == "ok" else 1)
E9EOF
printf 'drift\n'     > "$SCEN/drift-status"
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
SCEN_CWD="$TMP/e9repo/sub"   # the rail runs HERE; the tool is at $TMP/e9repo/tools/
SCEN_CWD_REPO="$REPO"        # identity matches, so the no-gate exception would apply if it were missed
SCEN_DRIFT_CMD=              # NO override — the default argv must find the root-anchored tool
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed — the tool was found from a subdirectory (root-anchored)" \
  || fail "SKIPPED from a subdirectory: a present gate read as absent (the round-2 fail-OPEN)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" \
  && pass "and the predicate actually RAN (not merely 'found')" \
  || fail "the predicate never ran — found-by-accident or not at all"
SCEN_CWD=                    # restore for later scenarios

# ── THE TRIGGER BOUNDARY — the round-3 P1 ───────────────────────────────
echo "── 17g-E12. a MEASURED distance below a non-zero drift threshold still consults the predicate"
# The skip arms asked "is `behind` non-empty?" where the real question is "is it
# ZERO?". With the default trigger only 0 reached them, so the difference was
# invisible; with a non-zero ATOMIC_LAND_DRIFT_TRIGGER a REAL distance lands in
# them, and the old form skipped a drift-red head WITHOUT calling the predicate
# while printing "measured current (0 behind)" — a false statement (measured in
# review round 3). Both arms must fail closed. The trigger is `0` in production;
# this scenario exercises the boundary the knob exists to make testable.
new_scen driftbelowtrigger
SCEN_DRIFT_CMD="$DRIFT"
SCEN_DRIFT_TRIGGER=20
printf 'CLEAN\n'     > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"   # A REAL distance, but below the threshold
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'drift\n'     > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (CLEAN arm) — a non-zero distance is never read as current" \
  || fail "SKIPPED a drift-red head below the threshold and called it 'measured current (0 behind)'"
grep -qF -- "drift-guard" "$SCEN/drift-calls" \
  && pass "and the predicate was consulted" \
  || fail "skipped without consulting the predicate (the round-3 P1)"

# The other arm: a NON-CLEAN state below the threshold takes the final `else`.
new_scen driftbelowtriggerblocked
SCEN_DRIFT_CMD="$DRIFT"
SCEN_DRIFT_TRIGGER=20
printf 'BLOCKED\n'   > "$SCEN/state"
printf '14\n'        > "$SCEN/behind"
printf 'drift\n'     > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed (the final arm) — the same question, one arm over" \
  || fail "SKIPPED a drift-red BLOCKED head below the threshold (the same 0/empty confusion)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" \
  && pass "and the predicate was consulted there too" \
  || fail "the final arm skipped without consulting the predicate"
SCEN_DRIFT_TRIGGER=

# ── THE THIRD SKIP PATH — CLEAN with an UNREADABLE distance ───────────────
echo "── 17g-E10. CLEAN with an UNREADABLE distance + drift RED ⇒ REFRESH (else it skips unmeasured)"
# `behind` is empty when the compare read fails. The `elif CLEAN` no-op used to absorb
# that case and return without ever reading the predicate — the one skip that assumed a
# state name was evidence about content. Under strict=false a genuinely-behind head
# reports CLEAN, so this is PR #7703's shape one unreadable read away.
new_scen cleannodistance
SCEN_DRIFT_CMD="$DRIFT"
printf 'CLEAN\n'     > "$SCEN/state"
printf '\n'          > "$SCEN/behind"   # empty = the compare API could not be read
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'drift\n'     > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
called "pr update-branch" \
  && pass "refreshed on an unreadable distance with a red predicate" \
  || fail "SKIPPED a drift-red CLEAN head on an unreadable distance (the third skip path)"
# The predicate must have been the REASON: a rail that refreshed on some other
# ground would also pass the line above (round-3 finding).
grep -qF -- "drift-guard" "$SCEN/drift-calls" \
  && pass "the predicate was consulted, not bypassed" \
  || fail "refreshed without consulting the predicate — the third skip path is not gated"

# ── …and the measured-current case must still be a cheap no-op ───────────
echo "── 17g-E11. CLEAN with a MEASURED-CURRENT head (0 behind) ⇒ no-op, no predicate call"
# behind=0 means the head contains the base, so no revert is possible and the no-op is
# correct WITHOUT a subprocess. Pins that the P2 fix did not turn every clean landing
# into a drift measurement (the cost the predicate adds).
new_scen cleancurrent
SCEN_DRIFT_CMD="$DRIFT"
printf 'CLEAN\n'     > "$SCEN/state"
printf '0\n'         > "$SCEN/behind"
printf 'false\n'     > "$SCEN/strict"
printf 'MERGEABLE\n' > "$SCEN/mergeable"
printf 'drift\n'     > "$SCEN/drift-status"
SCEN_RECORD_LOG=1
run_rail 42 --repo "$REPO" --poll 0
rc=$?
[ "$rc" -eq 0 ] && pass "lands (rc 0)" || fail "expected rc 0, got $rc"
called "pr update-branch" \
  && fail "refreshed a measured-current head" \
  || pass "no refresh (0 behind ⇒ nothing can revert)"
grep -qF -- "drift-guard" "$SCEN/drift-calls" \
  && fail "consulted the predicate for a measured-current head (needless subprocess)" \
  || pass "and did NOT spend a predicate call on it"

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
  # The four predicate anchors below are separated by INDENTATION, not by content:
  # the same predicate text sits at four sites. If two ever share a
  # leading-whitespace run, an anchored pattern mutates the FIRST only while the
  # suite still prints "class covered" — the second site ships unpinned (the
  # B19b/B20b trap, recorded above). "class covered" is an exit code and cannot say
  # WHICH site it covered, so pin the invariant the anchors rest on: each must
  # match exactly ONE line.
  for _ind in 14 12 10 8; do
    _n="$(awk -v n="$_ind" '
      { ind=0; while (substr($0, ind+1, 1) == " ") ind++
        if (ind == n && index($0, "drift_safe_of") && index($0, "= 1 ]")) c++ }
      END { print c+0 }' "$RAIL")"
    [ "$_n" = 1 ] \
      && pass "the ${_ind}-space predicate anchor matches exactly one line" \
      || fail "the ${_ind}-space predicate anchor matches $_n line(s) — a mutation could cover a different site and still report class covered"
  done
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
  mutate_and_expect_fail B11b 's/if \[ "\$age" -lt "\${ATOMIC_LAND_LOCK_GRACE:-60}" \]; then/if false; then/'
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
  # tested before the sleep). 7d's 30 s watchdog then fires, because an unclamped
  # `sleep "$POLL"` waits the full 60 s interval.
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
  # B24 (#7727): make the DRIFT arm's predicate INERT — the skip fires on
  # `mergeable` alone there, i.e. the revision before this fix. The failure it
  # prevents: a head whose merge would silently REVERT a path the base moved is
  # skipped forever, so the drift red can never clear and the PR is unlandable by
  # the rail's own action (live: PR #7703, 776 lines of silent revert; the refresh
  # was the whole fix). 17g-E1 must redden.
  # ⛔ ANCHORED TO 14 SPACES ON PURPOSE. `drift_safe_of` now appears in TWO arms, and
  # the BEHIND one comes FIRST in the file, so an unanchored pattern replaces THAT
  # arm instead — which is exactly what happened on the first cut of this pair: both
  # mutations mutated the same line, so the drift arm shipped UNPINNED while the suite
  # still reported both "covered". This is the B19b/B20b lesson repeating, one level
  # down: extending a predicate's use quietly narrows an unanchored mutation set.
  # `mutate_and_expect_fail` reports "reddened nothing — the mutation did not apply"
  # when the pattern stops matching, so re-indenting either arm fails LOUDLY.
  mutate_and_expect_fail B24  's/^              if \[ "\$\(drift_safe_of\)" = 1 \]; then/              if true; then/m'
  # B25 (#7727): the SIBLING arm must consult the predicate too. The failure it
  # prevents: fixing one arm and leaving the other — the same "mergeable means
  # landable" inference — skipping a drift-red head. Anchored to the BEHIND arm's
  # 12 spaces so it cannot silently mutate the drift arm instead. 17g-E7 must redden.
  mutate_and_expect_fail B25  's/^            if \[ "\$\(drift_safe_of\)" = 1 \]; then/            if true; then/m'
  # B26 (#7727): the THIRD skip path — the CLEAN arm's predicate, reached when the
  # distance is UNREADABLE or below a non-zero threshold. The failure it prevents:
  # gating two arms and leaving the third, so a CLEAN head whose compare read failed
  # is skipped unmeasured — the #7703 shape one unreadable read away. 17g-E10 and
  # 17g-E12 must redden.
  # ⛔ 8 SPACES, NOT 10: the final `else` arm's predicate is deliberately nested one
  # level deeper so that B26 and B27 cannot both match the same line. Two same-indent
  # sites would make one of these mutations cover only the first (the B19b/B20b trap).
  mutate_and_expect_fail B26  's/^        if \[ "\$\(drift_safe_of\)" = 1 \]; then/        if true; then/m'
  # B27 (#7727): the FOURTH site — the final `else` arm, reached by a non-CLEAN state
  # whose distance is below a non-zero threshold. Anchored to its 10 spaces (see B26).
  mutate_and_expect_fail B27  's/^          if \[ "\$\(drift_safe_of\)" = 1 \]; then/          if true; then/m'
  # B28 (#7727): the IDENTITY HOIST — the round-4 fail-OPEN. The failure it prevents:
  # the tool's measurement (or its absence) is attributed to a repo the cwd checkout
  # is NOT, so a wrong-repo green takes a skip. 17g-E6 and 17g-E15 must redden.
  mutate_and_expect_fail B28  's/^    if \[ -z "\$cwd_l" \] \|\| \[ "\$cwd_l" != "\$target_l" \]; then$/    if false; then/m'
  # B29 (#7727): the CLEAN arm's VALUE test. The failure it prevents: testing the
  # distance for EMPTINESS where the question is whether it is ZERO, so a measured
  # distance below a non-zero trigger is skipped unmeasured (the round-3 P1). 17g-E12
  # must redden.
  mutate_and_expect_fail B29  's/^        if \[ "\$\{behind:-\}" = "0" \]; then$/        if [ -n "\044behind" ]; then/m'
  # B30 (#7727): the ORIGIN-REMOTE assertion — the round-7 wrong-repo green. The
  # failure it prevents: the tool fetches the checkout's `origin` remote while
  # `gh repo view` prefers `upstream`, so a fork checkout passes the slug check and
  # its green is attributed to the target. 17g-E16 must redden.
  mutate_and_expect_fail B30  's/^      \*\) return 0 ;;$/      *) : ;;/m'
  # B32 (#7727): the no-gate exception's BASE-REF read. The failure it prevents:
  # a stale checkout (or a locally deleted file) reading "no gate" for a repo that HAS
  # one, and taking the skip unmeasured — a T1 skip with no measurement. 17g-E19 must
  # redden.
  mutate_and_expect_fail B32  's/^         && ! git -C "\$\{CWD_ROOT:-\.\}" cat-file -e "origin\/\$BASE:tools\/drift-guard\.py" 2>\/dev\/null/         \&\& :/m'
  # B33 (#7727): the scp-like authority arm. The failure it prevents: an origin of the
  # form `user:pw@github.com/o/n`, which git fetches from host `user` while a
  # first-`@` read names the TARGET's host — a T6 wrong-repo MATCH. 17g-E20 must redden.
  mutate_and_expect_fail B33  's/^      \*:\*@\*\) : ;;$/      *:*@*NEVERMATCH) : ;;/m'
  # B31 (#7727): the HOST assertion. The failure it prevents: a same-slug remote on a
  # DIFFERENT host (a mirror, a GitLab/GHE path) is a different repository, and its
  # green would be attributed to the target. 17g-E17 must redden.
  mutate_and_expect_fail B31  's/^    if \[ -z "\$target_host_l" \] \|\| \[ "\$origin_host_l" != "\$target_host_l" \]; then$/    if false; then/m'
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
