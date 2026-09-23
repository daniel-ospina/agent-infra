#!/usr/bin/env bash
# atomic-land.sh — the atomic land unit: update → verify → record → land (#1367).
#
# WHY THIS EXISTS. Two required conditions on `main` are jointly unsatisfiable
# while `main` moves: `strict: true` requires an up-to-date head, and the
# head-bound review evidence (`ai-review-gate`, and the local review-enforcer
# merge gate) must be bound to the head sha. Satisfying the first MOVES the head
# and stales the record; `main` advances every ~20-40 min while a full CI cycle
# is ~50 min, so the four steps performed as separate agent turns lose the
# window and the attestation dies for nothing. The measured shape is tortoise
# #4764 (48/69 open PRs with no valid attestation) and the O3 rebase sweep
# (22 updated, 17 fresh attestations invalidated, 0 landed).
#
# The owner's ruling on the order (tortoise #4764, comment 2026-09-22) is:
#
#   1. update      — bring the branch up to date with the base   (moves the head)
#   2. VERIFY      — the checks at the NEW head                  (step 2 is mandatory:
#                                                                  a base move can change
#                                                                  the code AROUND the
#                                                                  reviewed lines)
#   3. RECORD      — record-review.sh at the NEW head
#   4. land        — the repo's mandated rail, never a hand-rolled merge
#
# Steps 1-3 are atomic per PR: an update that ends without a record at the new
# head has consumed the previous attestation and produced nothing landable.
#
# WHAT THIS SCRIPT IS NOT. It CANNOT review. It carries an EXISTING signed
# verdict across a base-only update — `record-review.sh`'s carry-forward arm
# (agent-infra #767) fires iff the PR already carries an AUTHENTIC marker whose
# `diff=` equals the live three-dot diff, so the head move is provably a no-op
# to the reviewed artifact. When the diff changed, or no such evidence exists,
# the record step exits 3 and this rail STOPS and names the fresh review
# required. It never writes a record itself, and it never merges directly.
#
# FAIL-CLOSED INVARIANTS (this is gate/enforcement code):
#   * NO DEPENDENCY ON `strict` / branch protection. The rail never reads a
#     protection setting and is correct with `strict` ON or OFF — that is the
#     point of the rail: the T2 protection window must become unnecessary. Its
#     inputs are the PR's own state (head, base, base MERGE BASE, checks) and the
#     two scripts that own the review and the merge. `BEHIND` is used only as a
#     head/base DIVERGENCE signal ("the head is out of date"), never as a proxy
#     for a protection setting: the documented enum semantics say BEHIND can
#     occur with or without strict, and strict is only what makes it block.
#   * No accepted-verdict review record → refuse before any mutation.
#   * A draft → refuse before any CI work (`gh` refuses to merge a draft).
#   * A changed/unprovable diff → the record step refuses (exit 3) → STOP.
#   * The merge is `admin-merge.sh`, whose own evidence + decision own the
#     merge; this script adds no merge path.
#   * The merge is CONFIRMED by polling the PR's merged state — never inferred
#     from the rail's exit status alone (#1359: the rail once printed "merged"
#     while the PR was still open).
#   * `--dry-run` mutates nothing: no update, no record, no comment, no merge.
#
# Usage:
#   scripts/atomic-land.sh <PR> [--repo owner/repo] [--dry-run] [--no-wait]
#                              [--wait-timeout S] [--poll S] [--max-rounds N]
#                              [--no-cite] [-- <extra admin-merge flags>]
#
#   --repo owner/repo   repo for the gh calls (default: gh's own resolution)
#   --dry-run           compute + print the plan; mutate NOTHING. The land step
#                       is invoked with `--dry-run` appended, so its verdict is
#                       a read-only inspection.
#   --no-wait           do not wait for the head's checks to become terminal;
#                       hand the head to the rail as-is (its own "the head must
#                       have been tested" precondition then decides).
#   --wait-timeout S    bound on the terminal-CI wait (default 5400)
#   --poll S            poll interval for the waits (default 30)
#   --max-rounds N      rounds of update→verify→record→land (default 2, max 5):
#                       a base advance mid-unit can return the PR to BEHIND, and
#                       the carry-forward makes one more round safe.
#   --no-cite           do not post the reuse citation comment after a carry-forward
#   -- <flags>          passed through to admin-merge.sh (e.g. -- --merge)
#
# Exit: 0 = landed (or a --dry-run inspection completed); 1 = STOP (a named
#       refusal — fresh review required, base red, checks not terminal, merge
#       failed or unconfirmed); 2 = usage/config error.
#
# Env seams (tests):
#   ATOMIC_LAND_GH          the gh command (default: gh)
#   ATOMIC_LAND_RECORD_SH   record-review.sh (default: sibling record-review.sh,
#                           else $HOME/.pi/agent/scripts/record-review.sh)
#   ATOMIC_LAND_ADMIN_MERGE admin-merge.sh (default: sibling admin-merge.sh)
#
# The accepted-verdict list mirrors `ACCEPTED_VERDICTS` in
# extensions/review-enforcer/index.ts. If that list widens, widen this one too.

set -uo pipefail

PR=""
REPO=""
DRY_RUN=0
NO_WAIT=0
NO_CITE=0
WOULD_UPDATE=0
WAIT_TIMEOUT=5400
POLL=30
MAX_ROUNDS=2
MERGE_FLAGS=()

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${ATOMIC_LAND_GH:-gh}"
RECORD_SH="${ATOMIC_LAND_RECORD_SH:-}"
ADMIN_MERGE="${ATOMIC_LAND_ADMIN_MERGE:-$SELF_DIR/admin-merge.sh}"

if [ -z "$RECORD_SH" ]; then
  if [ -x "$SELF_DIR/record-review.sh" ]; then
    RECORD_SH="$SELF_DIR/record-review.sh"
  else
    RECORD_SH="$HOME/.pi/agent/scripts/record-review.sh"
  fi
fi

# Mirror of extensions/review-enforcer/index.ts ACCEPTED_VERDICTS.
ACCEPTED_VERDICTS="clean clean-micro clean-low"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
say()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }
stop() { err "⛔ atomic-land: STOP — $*"; exit 1; }

# ── argv ─────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)         REPO="${2:-}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --no-wait)      NO_WAIT=1; shift ;;
    --no-cite)      NO_CITE=1; shift ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --poll)         POLL="${2:-}"; shift 2 ;;
    --max-rounds)   MAX_ROUNDS="${2:-}"; shift 2 ;;
    --help|-h)      usage; exit 0 ;;
    --)             shift; MERGE_FLAGS=("$@"); break ;;
    -*)             err "atomic-land: unknown option $1"; usage >&2; exit 2 ;;
    *)              PR="$1"; shift ;;
  esac
done

[ -n "$PR" ] || { err "atomic-land: a PR number is required"; usage >&2; exit 2; }
case "$PR" in *[!0-9]*) err "atomic-land: PR must be numeric (got $PR)"; exit 2 ;; esac
case "$WAIT_TIMEOUT" in ''|*[!0-9]*) err "atomic-land: --wait-timeout must be a non-negative integer"; exit 2 ;; esac
case "$POLL" in ''|*[!0-9]*) err "atomic-land: --poll must be a non-negative integer"; exit 2 ;; esac
case "$MAX_ROUNDS" in ''|*[!0-9]*) err "atomic-land: --max-rounds must be a positive integer"; exit 2 ;; esac
[ "$MAX_ROUNDS" -ge 1 ] || { err "atomic-land: --max-rounds must be >= 1"; exit 2; }
[ "$MAX_ROUNDS" -le 5 ] || { err "atomic-land: --max-rounds is bounded at 5"; exit 2; }
[ -x "$ADMIN_MERGE" ] || [ -f "$ADMIN_MERGE" ] || stop "no admin-merge.sh at $ADMIN_MERGE"
[ -f "$RECORD_SH" ] || stop "no record-review.sh at $RECORD_SH"

repo_args=()
[ -n "$REPO" ] && repo_args=(--repo "$REPO")

gh_() { "$GH" "$@"; }

# ── B11 — one rail per PR ─────────────────────────────────────────────────
# Two concurrent rails on the SAME PR interleave update/record/land: each can
# move the head the other verified, and each can re-record on the other's head.
# B9/B10 catch the RESULTING move, but a check is not a mutual exclusion — the
# interleaving can still produce two records and two merges. A per-(repo,PR)
# lock makes the unit exclusive. `mkdir` is the atomic primitive (macOS has no
# flock); a crashed holder is reclaimed by PID liveness, bounded to one reclaim.
LOCKDIR=""
acquire_lock() {
  LOCKDIR="${TMPDIR:-/tmp}/atomic-land-$(printf '%s' "$REPO" | tr '/' '-')-$PR.lock"
  if mkdir "$LOCKDIR" 2>/dev/null; then :; else
    local other=""
    other="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      stop "another atomic-land is already running for $REPO#$PR (pid $other) — refusing to interleave"
    fi
    rm -rf "$LOCKDIR"                       # stale holder — reclaim ONCE
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
      stop "could not acquire the per-PR lock ($LOCKDIR) — refusing to race"
    fi
  fi
  printf '%s\n' "$$" > "$LOCKDIR/pid"
  trap 'rm -rf "$LOCKDIR"' EXIT INT TERM HUP
}

# ── state ────────────────────────────────────────────────────────────────
HEAD=""; BASE=""; MERGE_STATE=""; IS_DRAFT="false"
RECORD_FILE=""; RECORD_HEAD=""; RECORD_VERDICT=""; RECORD_MB=""
CERT_BASE=""; CERT_MB=""; CERT_BASE_TIP=""

# The merge base of `compare/<base>...<head>` — the commit that identifies the
# certified content. It is INVARIANT under a base branch that merely ADVANCES
# (main's new commits are not ancestors of the head) and MOVES exactly when the
# base is repointed or rewritten (#1348). B10 binds to THIS, not to the base tip
# and not to `mergeStateStatus`.
#
# WHY `mergeStateStatus` CANNOT CARRY THIS (evidence, 2026-09-23). `BEHIND` is a
# HEAD/BASE DIVERGENCE signal — GitHub's `PullRequestMergeStateStatus.BEHIND`
# means only "the head ref is out of date"; it is NOT produced by `strict: true`
# and can occur with or without the "require branches up to date" protection
# (strict is what makes BEHIND *block* a merge). It says nothing about the base's
# IDENTITY: `gh pr edit --base` can repoint the PR while the head is `CLEAN`, so
# the certified diff (`compare/<base>...<head>`) changes while every
# head-bound check still passes. Verified against the documented enum semantics,
# not assumed — an untested assumption about a protection setting is exactly the
# class this rail exists to catch.
merge_base_of() { # <base> <head>
  gh_ api "repos/$REPO/compare/$1...$2" --jq .merge_base_commit.sha 2>/dev/null || true
}
# The base branch's TIP at a moment in time. A concurrent merge ADVANCES it while
# leaving the merge base unchanged, so it is the signal for B12: the checks were
# verified against the old tip and did not cover the new one. `--admin` bypasses
# `strict`, so the rail must re-establish the up-to-date guarantee itself rather
# than depend on the protection setting.
base_tip() {
  gh_ api "repos/$REPO/pulls/$PR" --jq .base.sha 2>/dev/null || true
}

resolve_repo() {
  if [ -z "$REPO" ]; then
    REPO="$(gh_ repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  case "$REPO" in
    */*) ;;
    *) stop "could not resolve the repo (pass --repo owner/repo)" ;;
  esac
}

resolve_state() {
  local line
  line="$(gh_ pr view "$PR" ${repo_args[@]+"${repo_args[@]}"} \
            --json headRefOid,baseRefName,mergeStateStatus,isDraft \
            --jq '"\(.headRefOid)\t\(.baseRefName)\t\(.mergeStateStatus)\t\(.isDraft)"' 2>/dev/null || true)"
  if [ -z "$line" ]; then stop "could not read PR #$PR state (gh/API failure?)"; fi
  HEAD="$(printf '%s' "$line" | cut -f1)"
  BASE="$(printf '%s' "$line" | cut -f2)"
  MERGE_STATE="$(printf '%s' "$line" | cut -f3)"
  IS_DRAFT="$(printf '%s' "$line" | cut -f4)"
  case "$HEAD" in
    ""|*[!0-9a-fA-F]*) stop "PR #$PR head is not a plain sha (got '${HEAD:-<empty>}')" ;;
  esac
}

# The review record file. Repo-qualified first (#426), legacy `<PR>.json` next
# (accepted only when it names no repo, or names THIS one).
read_record() {
  local qualified="$HOME/.pi/agent/reviews/${REPO%/*}-${REPO#*/}-$PR.json"
  local legacy="$HOME/.pi/agent/reviews/$PR.json"
  local candidate="" out=""
  if [ -f "$qualified" ]; then
    candidate="$qualified"
  elif [ -f "$legacy" ]; then
    local legacy_repo
    legacy_repo="$(python3 - "$legacy" <<'PY' 2>/dev/null || true
import json,sys
try: print(json.load(open(sys.argv[1])).get("repo",""))
except Exception: pass
PY
)"
    if [ -z "$legacy_repo" ] || [ "$legacy_repo" = "$REPO" ]; then candidate="$legacy"; fi
  fi
  [ -n "$candidate" ] || return 1
  out="$(python3 - "$candidate" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
print(d.get("head_sha",""))
print(d.get("verdict",""))
print(d.get("merge_base_sha",""))
PY
)" || return 1
  RECORD_FILE="$candidate"
  RECORD_HEAD="$(printf '%s' "$out" | sed -n '1p')"
  RECORD_VERDICT="$(printf '%s' "$out" | sed -n '2p')"
  RECORD_MB="$(printf '%s' "$out" | sed -n '3p')"
  return 0
}

verdict_accepted() {
  local v
  for v in $ACCEPTED_VERDICTS; do [ "$v" = "$1" ] && return 0; done
  return 1
}

# ── step 1: update ───────────────────────────────────────────────────────
do_update() { # 0 = updated, 3 = not behind (no-op)
  local before="$HEAD" after="" i
  if [ "$MERGE_STATE" != "BEHIND" ]; then
    say "atomic-land: [1/4] update — mergeStateStatus=$MERGE_STATE, not BEHIND — nothing to update"
    return 3
  fi
  say "atomic-land: [1/4] update — PR #$PR is BEHIND; updating the branch (head ${before:0:12}…)"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "atomic-land:     (dry-run) would run: gh pr update-branch $PR"
    WOULD_UPDATE=1
    return 3
  fi
  gh_ pr update-branch "$PR" ${repo_args[@]+"${repo_args[@]}"} >/dev/null 2>&1 \
    || stop "gh pr update-branch failed for #$PR (conflict, or not updatable)"
  # The new head must appear; a bounded poll, because the ref update is async.
  i=0
  while [ "$i" -lt 20 ]; do
    after="$(gh_ pr view "$PR" ${repo_args[@]+"${repo_args[@]}"} --json headRefOid --jq .headRefOid 2>/dev/null || true)"
    if [ -n "$after" ] && [ "$after" != "$before" ]; then HEAD="$after"; break; fi
    i=$((i + 1)); sleep "$POLL"
  done
  [ -n "$after" ] && [ "$after" != "$before" ] \
    || stop "the update did not move the head (still ${before:0:12}…) — nothing to carry a record onto"
  say "atomic-land:     updated: ${before:0:12}… → ${HEAD:0:12}…"
  return 0
}

# ── step 2: verify (the head's checks must be terminal) ──────────────────
wait_terminal() {
  if [ "$NO_WAIT" -eq 1 ]; then
    say "atomic-land: [2/4] verify — --no-wait: the rail's own tested-head precondition decides"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "atomic-land: [2/4] verify — (dry-run) would wait up to ${WAIT_TIMEOUT}s for terminal checks"
    return 0
  fi
  say "atomic-land: [2/4] verify — waiting (≤${WAIT_TIMEOUT}s) for the checks at ${HEAD:0:12}… to be terminal"
  local elapsed=0 pending completed
  while :; do
    pending="$(gh_ api "repos/$REPO/commits/$HEAD/check-runs" \
                 --jq '[.check_runs[] | select(.status != "completed")] | length' 2>/dev/null || echo "?")"
    completed="$(gh_ api "repos/$REPO/commits/$HEAD/check-runs" \
                 --jq '[.check_runs[] | select(.status == "completed")] | length' 2>/dev/null || echo "?")"
    if [ "$pending" = "0" ] && [ "$completed" != "0" ] && [ "$completed" != "?" ]; then
      say "atomic-land:     checks terminal — $completed completed, 0 pending"
      return 0
    fi
    if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
      stop "the checks at ${HEAD:0:12}… were not terminal within ${WAIT_TIMEOUT}s (pending=${pending}, completed=${completed}) — re-run the rail later; nothing was recorded or merged"
    fi
    sleep "$POLL"; elapsed=$((elapsed + POLL))
  done
}

# ── step 3: record (carry the existing verdict forward, or STOP) ─────────
do_record() { # 0 = record is fresh/at head, 1 = refused (fresh review needed)
  if [ "$RECORD_HEAD" = "$HEAD" ]; then
    if [ "$WOULD_UPDATE" -eq 1 ]; then
      say "atomic-land: [3/4] record — (dry-run) the pending update moves the head, so the record would be re-derived there (carry-forward iff the reviewed diff is unchanged)"
    else
      say "atomic-land: [3/4] record — the record is already at ${HEAD:0:12}… (verdict=$RECORD_VERDICT); no re-record"
    fi
    return 0
  fi
  say "atomic-land: [3/4] record — record is at ${RECORD_HEAD:0:12}…, head is ${HEAD:0:12}…"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "atomic-land:     (dry-run) would run: record-review.sh $PR ${RECORD_HEAD:0:12}… $RECORD_VERDICT $REPO (carry-forward)"
    return 0
  fi
  local log rc prior="$RECORD_HEAD"
  log="$(mktemp "${TMPDIR:-/tmp}/atomic-land-record.XXXXXX")"
  bash "$RECORD_SH" "$PR" "$prior" "$RECORD_VERDICT" "$REPO" >"$log" 2>&1
  rc=$?
  sed 's/^/atomic-land:     record-review: /' "$log" >&2
  if [ "$rc" -eq 3 ]; then
    err "atomic-land: the recorded verdict cannot be carried to ${HEAD:0:12}… — the reviewed diff CHANGED (or no prior signed evidence for it exists)."
    err "atomic-land: a FRESH review of the new head is required; this rail cannot author one. Nothing was merged."
    rm -f "$log"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$log"
    stop "record-review.sh exited $rc — refusing to land without a record"
  fi
  # Cite BEFORE overwriting the prior binding (the citation names both ends).
  if [ "$NO_CITE" -eq 0 ]; then cite_reuse "$log" "$prior"; fi
  rm -f "$log"
  # The re-record certified the LIVE base at THIS head, so the in-memory prior
  # merge base is now stale and must not drive the pre-land comparison (it would
  # false-block the very carry-forward the rail exists for). Refresh from disk,
  # and fall back to the certified base if the file could not be re-read.
  read_record || true
  RECORD_HEAD="$HEAD"
  return 0
}

# The reuse citation (tortoise #4764 ruling): record the reuse AS REUSE, with
# the equivalence evidence, rather than silently re-stamping the verdict. A
# COMMENT, never a body edit — the body carries the attestation and editing it
# wipes it (agent-infra #1224).
#
# ⛔ The citation carries NO marker segment. The review-marker format is a
# CROSS-REPO CONTRACT: a new marker kind inherits a land order (the consumer
# regex must accept it BEFORE any producer emits it), or every signed marker
# reads malformed fleet-wide (#3076 shape). Marker WRITING therefore stays
# where the fleet's regexes already know it — `record-review.sh`. This rail
# writes prose only, and its one write is this comment; it never touches the
# record and never edits the PR body.
cite_reuse() { # <record-review log> <prior head>
  local diff="" prior="$2"
  diff="$(grep -oE 'diff=[0-9a-f]{64}' "$1" 2>/dev/null | head -1 | cut -d= -f2)"
  local body="atomic-land: reused verdict \`$RECORD_VERDICT\` for ${HEAD:0:12}… from prior head ${prior:0:12}…
The head moved by a base-only update, and \`record-review.sh\` re-recorded the prior signed verdict"
  if [ -n "$diff" ]; then
    body="$body for the byte-identical three-dot diff (\`diff=$diff\`)."
  else
    body="$body after its carry-forward guard proved the reviewed diff unchanged."
  fi
  gh_ pr comment "$PR" ${repo_args[@]+"${repo_args[@]}"} --body "$body" >/dev/null 2>&1 \
    || err "atomic-land: ⚠️ could not post the reuse citation comment (non-fatal)"
}

# ── step 4: land (the mandated rail) + confirm ───────────────────────────
do_land() {
  say "atomic-land: [4/4] land — admin-merge.sh $PR ${MERGE_FLAGS[*]:-}"
  local flags=()
  if [ "$DRY_RUN" -eq 1 ]; then flags+=(--dry-run); fi
  if [ "${#MERGE_FLAGS[@]}" -gt 0 ]; then flags+=("${MERGE_FLAGS[@]}"); fi
  bash "$ADMIN_MERGE" "$PR" ${repo_args[@]+"${repo_args[@]}"} ${flags[@]+"${flags[@]}"}
  return $?
}

confirm_merged() { # <max polls: 1 = a single immediate check>
  local max="${1:-${ATOMIC_LAND_CONFIRM_MAX:-60}}" i state
  case "$max" in ''|*[!0-9]*) max=1 ;; esac
  [ "$DRY_RUN" -eq 1 ] && return 0
  for i in $(seq 1 "$max"); do
    state="$(gh_ api "repos/$REPO/pulls/$PR" --jq 'if .merged then "MERGED" else "OPEN" end' 2>/dev/null || echo OPEN)"
    [ "$state" = "MERGED" ] && { say "atomic-land: ✅ merged PR #$PR"; return 0; }
    [ "$max" -le 1 ] && break
    sleep 10
  done
  err "atomic-land: ⛔ the merge was NOT confirmed — PR #$PR is still $state (the land step's exit status alone is not proof; #1359)"
  return 1
}

# ── main ─────────────────────────────────────────────────────────────────
resolve_repo
[ "$DRY_RUN" -eq 1 ] && say "atomic-land: DRY RUN — nothing will be mutated"
# Exclusive per-PR unit (B11). A dry run mutates nothing, so it takes no lock.
[ "$DRY_RUN" -eq 0 ] && acquire_lock

resolve_state
if [ "$IS_DRAFT" = "true" ]; then
  stop "PR #$PR is a DRAFT — gh refuses to merge a draft; run \`gh pr ready $PR\` first"
fi
if ! read_record; then
  stop "no review record for $REPO#$PR — there is no verdict to carry and this rail cannot review; run the review, then record"
fi
if ! verdict_accepted "$RECORD_VERDICT"; then
  stop "the record for $REPO#$PR has verdict '$RECORD_VERDICT' — only [$ACCEPTED_VERDICTS] unlocks a merge"
fi
case "$RECORD_HEAD" in
  ""|*[!0-9a-fA-F]*) stop "the record for $REPO#$PR carries no usable head_sha" ;;
esac
# B10 (pre-unit) — a FRESH record that names its own base (clean-low, #1348) must
# be bound to the SAME merge base the PR has now; otherwise the PR was repointed
# before this unit and the certified diff is not the diff that would merge. A
# STALE record is skipped here: it is re-derived by the record step, whose own
# diff guard refuses a repointed diff. For clean/clean-micro the record carries
# no base field, so this arm cannot fire — declared residual, agent-infra #1362.
if [ "$RECORD_HEAD" = "$HEAD" ] && [ -n "$RECORD_MB" ]; then
  live_mb="$(merge_base_of "$BASE" "$HEAD")"
  if [ -z "$live_mb" ] || [ "$live_mb" != "$RECORD_MB" ]; then
    stop "the record was certified against merge base ${RECORD_MB:0:12}… but this PR's base is ${live_mb:-unreadable} — the base was repointed BEFORE this unit (B10); re-review and re-record"
  fi
fi
say "atomic-land: PR #$PR  head=${HEAD:0:12}…  base=$BASE  state=$MERGE_STATE  record=${RECORD_VERDICT}@${RECORD_HEAD:0:12}…"

round=1
while :; do
  say "atomic-land: ── round $round/$MAX_ROUNDS ──"
  do_update
  # Capture the BASE the CHECKS are verified against, at the start of verification
  # (B10): the base branch name and its MERGE BASE. A move between here and the
  # land is refused, so the rail can never verify against base X and land against
  # base Y. `mergeStateStatus` cannot carry this — BEHIND is a head/base divergence
  # signal (head out of date), not a strict signal and not a base-identity signal;
  # a repoint can happen while the head is CLEAN.
  CERT_BASE="$BASE"
  CERT_MB="$(merge_base_of "$BASE" "$HEAD")"
  CERT_BASE_TIP="$(base_tip)"
  if [ -z "$CERT_MB" ]; then
    stop "could not read the merge base of $BASE...${HEAD:0:12}… — refusing to certify without a base binding (B10)"
  fi
  wait_terminal
  if ! do_record; then exit 1; fi
  # B9 — the head must not move between the RECORD and the LAND. The record binds
  # a sha and the land step uses `--admin` (bypassing the remote required check),
  # so a push inside this window would land bytes the record does not cover.
  # B10 — the BASE must not be repointed or rewritten after the checks were
  # verified. Every head-bound check still passes on a `gh pr edit --base`, while
  # what merges changes (agent-infra #1362). A base that merely ADVANCED does not
  # move the merge base, so it is not a repoint and is not refused.
  if [ "$DRY_RUN" -eq 0 ]; then
    pre="$(gh_ pr view "$PR" ${repo_args[@]+"${repo_args[@]}"} \
            --json headRefOid,baseRefName \
            --jq '"\(.headRefOid)\t\(.baseRefName)"' 2>/dev/null || true)"
    now="$(printf '%s' "$pre" | cut -f1)"
    now_base="$(printf '%s' "$pre" | cut -f2)"
    if [ -z "$now" ] || [ -z "$now_base" ]; then
      stop "could not re-resolve the head/base before landing — refusing to land unverified"
    fi
    if [ "$now" != "$HEAD" ]; then
      say "atomic-land: the head moved between the record (${HEAD:0:12}…) and the land (${now:0:12}…) — the record no longer covers what would merge"
      resolve_state
      if [ "$round" -lt "$MAX_ROUNDS" ]; then
        say "atomic-land: re-deriving the record at the new head — another round"
        round=$((round + 1))
        continue
      fi
      stop "the head moved between the record and the land and no round remains — re-run the rail"
    fi
    if [ "$now_base" != "$CERT_BASE" ]; then
      stop "the PR base was repointed ($CERT_BASE → $now_base) after the record — the certified diff is no longer the diff that would merge (B10); re-review and re-record against the new base"
    fi
    now_mb="$(merge_base_of "$now_base" "$now")"
    if [ -z "$now_mb" ] || [ "$now_mb" != "$CERT_MB" ]; then
      stop "the base's merge base moved (${CERT_MB:0:12}… → ${now_mb:0:12}…) after the record — what merges is not what was certified (B10); re-review and re-record"
    fi
    # (A pre-unit repoint on a FRESH record is checked once at startup, below.)
    # B12 — a concurrent merge ADVANCED the base (same branch, same merge base)
    # after these checks were verified. `--admin` bypasses `strict`, so landing
    # now would merge B onto a base its checks never covered (with 25+ lanes this
    # is the common case, not an edge). The certified DIFF is unchanged (the
    # merge base did not move), so the fix is to RE-VERIFY, not to re-review.
    if [ -n "$CERT_BASE_TIP" ]; then
      now_tip="$(base_tip)"
      if [ -z "$now_tip" ]; then
        stop "could not re-read the base tip before landing — refusing to land unverified (B12)"
      fi
      if [ "$now_tip" != "$CERT_BASE_TIP" ]; then
        say "atomic-land: the base ADVANCED after verification (${CERT_BASE_TIP:0:12}… → ${now_tip:0:12}…) — the checks did not cover the new base"
        resolve_state
        if [ "$round" -lt "$MAX_ROUNDS" ]; then
          say "atomic-land: re-verifying against the advanced base — another round (the reviewed diff is unchanged; the review is reused, the CHECK is re-run)"
          round=$((round + 1))
          continue
        fi
        stop "the base advanced after verification and no round remains to re-verify — re-run the rail (B12)"
      fi
    fi
  fi
  if do_land; then
    confirm_merged || exit 1
    exit 0
  fi
  # The land step refused or failed. CONFIRM the merge before concluding failure:
  # a merge can complete server-side while the command exits non-zero (#193), and
  # a status line alone is not proof either way (#1359).
  if confirm_merged 1; then exit 0; fi
  # If the PR is BEHIND again (a base advance mid-unit), one more round is safe —
  # the carry-forward carries the same verdict — else stop and relay the reason.
  resolve_state
  if [ "$MERGE_STATE" = "BEHIND" ] && [ "$round" -lt "$MAX_ROUNDS" ]; then
    say "atomic-land: the base advanced mid-unit (BEHIND again) — another round"
    round=$((round + 1))
    continue
  fi
  stop "the land step did not merge and the PR is not BEHIND ($MERGE_STATE) — the reason is above; nothing was merged"
done
