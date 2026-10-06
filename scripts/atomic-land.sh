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
#   3. RECORD      — record-review.sh, given the PRIOR head as the equivalence
#                    input; its carry-forward arm (#767) re-binds the record to
#                    the NEW head iff the reviewed diff is content-unchanged
#                    (sha256 over the NORMALIZED diff, #1362 D1 — the rendering
#                    may re-flow across a base move; the change may not)
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
#   * THE REFRESH DOES NOT DEPEND ON A PROTECTION SETTING — WITH ONE DECLARED,
#     LIVE, NARROW EXCEPTION (#1565). The rail's inputs are the PR's own state
#     (head, base, base MERGE BASE, checks) and the two scripts that own the
#     review and the merge. `BEHIND` is used only as a head/base DIVERGENCE
#     signal ("the head is out of date"), never as a proxy for a protection
#     setting: the documented enum semantics say BEHIND can occur with or without
#     strict, and strict is only what makes it block.
#     OVERRIDES: the former "the rail never reads a protection setting, and is
#     correct with strict ON or OFF" invariant — narrowed to ONE positive read of
#     `strict` per invocation (strict_of()), at the step-1 decision point ONLY, in
#     BOTH step-1 arms: the BEHIND enum arm, AND the base-drift arm for the
#     landable states `CLEAN|UNSTABLE` only. #1565's ruling that the drift arm must
#     stay ungated ("a BLOCKED PR is still mergeable: true", so gating it would
#     skip the refresh #1533 needed) is NARROWED, not reversed — `BLOCKED`, every
#     other or unknown state, and any unreadable read still refresh. The record
#     lives on agent-infra#1565, whose own text carries the matching marker.
#     Rationale, measured (#1565): the refresh's cost is a head move, which
#     invalidates the head-bound review record (clause B5), forces a full CI run at
#     the new head (critical path 17.1m median / 19.8m max), and then makes the rail
#     wait up to 5400s for those checks to go terminal — while `strict: false` means
#     the pin buys no mergeability at all (nine PRs sat OPEN+MERGEABLE unlanded for
#     ~2h paying it). The read is LIVE and per-invocation (never cached: a stored
#     belief about branch protection cannot disagree with GitHub, it can only be
#     silently wrong) and it FAILS CLOSED — anything but a positive `false`
#     (404/403/`null`/empty: protection unconfigured, or a token without admin on
#     the repo) keeps the refresh exactly as it was. The merge and the record never
#     consult it. ATOMIC_LAND_REFRESH_ALWAYS=1 restores the unconditional refresh
#     in BOTH arms.
#     The gate applies to the BEHIND arm AND to the base-drift arm below, for the
#     states that are ALREADY LANDABLE — `CLEAN` (every check passed) and `UNSTABLE`
#     (the REQUIRED checks passed; only non-required ones fail or pend), both
#     landable under `strict: false`, which is the #7230 non-termination. The drift
#     arm stays conditional on `behind_by > 0` and is NOT gated for `BLOCKED`,
#     because it exists for the #1533 case — a BLOCKED branch whose drift red could
#     never resolve without an update — and a BLOCKED PR is still `mergeable: true`
#     (no conflicts; it has a red required leg). Gating that state would skip exactly
#     the refresh #1533 needed.
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
#   ATOMIC_LAND_CONFIRM_MAX how many times to confirm the merge via the API
#                           (default: 60) — a non-zero admin-merge exit is never
#                           read as success; the .merged poll is the only proof.
#   ATOMIC_LAND_LOCK_DIR    the per-PR lock directory (default: $HOME/.pi/agent/locks).
#                           Deliberately NOT under $TMPDIR, which is caller-controlled.
#   ATOMIC_LAND_LOCK_GRACE  seconds a pid-less lock is treated as LIVE, not stale
#                           (default: 60) — closes the mkdir→pid TOCTOU (B11).
#   ATOMIC_LAND_UNKNOWN_POLLS  re-polls for a transient `mergeStateStatus=UNKNOWN`
#                           before failing closed (default: 5).
#   ATOMIC_LAND_REFRESH_ALWAYS  1 = always refresh a drifting head (a BEHIND enum, or
#                               base drift on a landable state), ignoring the live
#                               `strict` read (the #1565 fail-safe restore)
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
# A CAP, not just a shape check. `[ "$elapsed" -ge "$WAIT_TIMEOUT" ]` compares as
# a machine integer, and a literal too wide for that comparison ERRORS — and a
# failing `[` is FALSE, so an oversized value silently DISABLES the bound and the
# rail loops forever while holding the PR's lock. That is the #1395 item-1 defect
# arriving by a second door, and it is the same class B12b pins (a guard a failed
# comparison turns OFF). Capping it also rejects an oversized literal HERE, via
# that very error, so this line fails closed by construction. `2>/dev/null` hides
# that raw `[: integer expression expected`, which is bash's, not our diagnostic.
# 86400 = 24h.
[ "$WAIT_TIMEOUT" -le 86400 ] 2>/dev/null || { err "atomic-land: --wait-timeout must be at most 86400s (24h)"; exit 2; }
case "$POLL" in ''|*[!0-9]*) err "atomic-land: --poll must be a non-negative integer"; exit 2 ;; esac
# `--poll` is capped for the same reason, and it is the fix for the OTHER waits:
# two loops in this rail are bounded by an ITERATION COUNT (5 polls for a lazy
# merge state, 20 for the async ref update), so an unbounded interval multiplies
# their bound instead of honouring it — `/bin/sleep` takes up to ~68 years, i.e.
# a "bounded" poll that outlives the run while holding the per-PR lock. The
# default is 30; 300 is well past any sane re-check cadence, and it keeps those
# two loops to 25 min and 100 min instead of 68 years. Fails closed on an
# oversized literal via the same comparison error as the cap above.
[ "$POLL" -le 300 ] 2>/dev/null || { err "atomic-land: --poll must be at most 300s"; exit 2; }
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
  # B11 — the lock base is NOT derived from TMPDIR. TMPDIR is caller-controlled,
  # so a second rail with a different TMPDIR would use a different lock path and
  # both would land (reproduced). Keep it in a per-user fixed location instead.
  local dir="${ATOMIC_LAND_LOCK_DIR:-$HOME/.pi/agent/locks}"
  mkdir -p "$dir" 2>/dev/null || true
  LOCKDIR="$dir/atomic-land-$(printf '%s' "$REPO" | tr '/' '-')-$PR.lock"
  # B11 — the RECLAIM is the hard part. Deciding "stale" and then `rm -rf` + `mkdir`
  # is check-then-act: two rails can both decide stale, and the second's `rm -rf`
  # deletes the first's freshly-created lock — both then land (reproduced at
  # ~25-38% naturally against a stale lock). The steal is therefore an ATOMIC
  # RENAME: `mv` of the lock directory succeeds for exactly ONE contender, so the
  # others fall through to the loop and re-read the lock that now exists.
  local tries=0 other age now_s mt stolen
  while :; do
    tries=$((tries + 1))
    if mkdir "$LOCKDIR" 2>/dev/null; then break; fi
    other="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      stop "another atomic-land is already running for $REPO#$PR (pid $other) — refusing to interleave"
    fi
    # An ABSENT pid is not proof of a dead holder (the directory exists before the
    # pid is written), so a young pid-less lock is LIVE and refuses; only one older
    # than the grace is a reclaim candidate.
    if [ -z "$other" ]; then
      now_s="$(date +%s)"
      # Portable mtime read: GNU first, BSD second. A missing/unreadable mtime is
      # treated as age 0 (i.e. LIVE) so the failure direction stays fail-closed.
      mt="$({ stat -c %Y "$LOCKDIR" 2>/dev/null || stat -f %m "$LOCKDIR" 2>/dev/null; } || true)"
      case "$mt" in ''|*[!0-9]*) age=0 ;; *) age=$(( now_s - mt )) ;; esac
      if [ "$age" -lt "${ATOMIC_LAND_LOCK_GRACE:-60}" ]; then
        stop "another atomic-land holds the lock for $REPO#$PR (no pid yet — still starting) — refusing to interleave"
      fi
    fi
    # Stale: claim it by rename (atomic; at most one rail can win), then retry mkdir.
    stolen="$LOCKDIR.reclaim.$$"
    mv "$LOCKDIR" "$stolen" 2>/dev/null && rm -rf "$stolen"
    if [ "$tries" -ge 5 ]; then
      stop "could not acquire the per-PR lock ($LOCKDIR) — refusing to race"
    fi
  done
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
# How many commits the HEAD is behind the BASE. Same compare call merge_base_of()
# already makes — the response carries `behind_by`, so this is a second read of an
# existing response, not new machinery and not a new API.
#
# ⛔ Why the rail must not route on `mergeStateStatus` alone: a red REQUIRED check
# makes GitHub report BLOCKED, not BEHIND. Measured live over the non-draft PRs:
# 90 BLOCKED / 10 UNSTABLE / 6 DIRTY / 0 BEHIND. So a head that predates a base
# commit which is itself required for a gate leg (e.g. `9c432c6a4`, which CLASSIFIES
# `test_pack_extraction_slots_v31.py` for `manifest-integrity` — a leg of the
# required `python-ci-gate`) reads as BLOCKED, do_update did not fire, and the
# failure was self-sustaining: the stale head keeps failing the leg, the red keeps
# reading as BLOCKED, and nothing ever refreshes it. `behind_by` is the condition
# we actually want; the enum is a coarse proxy that NEVER says it for these PRs.
behind_by_of() { # <base> <head> -> N (empty on any unreadable/non-numeric reply)
  local n
  n="$(gh_ api "repos/$REPO/compare/$1...$2" --jq '.behind_by // 0' 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) echo ""; return 0 ;; esac
  echo "$n"
}
# ── the refresh gate: is the base pin worth its cost? (#1565) ─────────────
# THE ONE PLACE THIS RAIL READS A PROTECTION SETTING. Declared, LIVE (read at the
# decision point, never cached at startup), and NARROW: it gates ONLY the step-1
# refresh — never the merge, the record, the wait, or the check verdict.
#
# FAIL-CLOSED DIRECTION (this is gate code): the skip fires only on a POSITIVE
# `false` read of `required_status_checks.strict` AND a POSITIVE `true` mergeable.
# Every other outcome — an unreadable protection (404 when protection is not
# configured, or when the token lacks admin on the repo; 403; a rate-limited or
# empty reply), a null `required_status_checks`, or an unreadable `mergeable` —
# keeps the refresh exactly as it was before this gate existed.
strict_of() { # -> true | false | "" (empty = unreadable ⇒ the caller refreshes)
  local v
  v="$(gh_ api "repos/$REPO/branches/$BASE/protection" --jq '.required_status_checks.strict' 2>/dev/null || true)"
  case "$v" in true|false) printf '%s' "$v" ;; *) printf '' ;; esac
}
mergeable_of() { # -> true | false | "" (empty = unreadable ⇒ the caller refreshes)
  # ⛔ `gh pr view --json mergeable` IS NOT A BOOLEAN — it is the GraphQL enum STRING
  # (api/queries_pr.go: PullRequestMergeable = "MERGEABLE" | "CONFLICTING" |
  # "UNKNOWN"). MEASURED on PR #1566: `gh pr view 1566 --json mergeable --jq
  # .mergeable` prints `MERGEABLE`, while `gh api repos/…/pulls/1566 --jq .mergeable`
  # prints `true` for the SAME PR. A predicate that accepts only `true|false`
  # therefore NEVER matches the real CLI, which silently turns this gate INERT — and
  # the suite keeps passing as long as its fixture speaks the REST shape. Both the
  # predicate and the fixture were wrong in the first cut of #1565; a review caught
  # it. Do not "simplify" this back to a boolean test.
  local v
  v="$(gh_ pr view "$PR" ${repo_args[@]+"${repo_args[@]}"} --json mergeable --jq .mergeable 2>/dev/null || true)"
  case "$v" in
    MERGEABLE)   printf 'true'  ;;
    CONFLICTING) printf 'false' ;;
    *)           printf ''      ;;
  esac
}

# The base branch's TIP at a moment in time. A concurrent merge ADVANCES it while
# leaving the merge base unchanged, so it is the signal for B12: the checks were
# verified against the old tip and did not cover the new one. `--admin` bypasses
# `strict`, so the rail must re-establish the up-to-date guarantee itself rather
# than depend on the protection setting.
base_tip() {
  gh_ api "repos/$REPO/pulls/$PR" --jq .base.sha 2>/dev/null || true
}

# The review gate key — the SAME source and normalisation as the producer
# (scripts/record-review.sh: AI_REVIEW_GATE_KEY, else ~/.pi/agent/.ai-review-gate-key).
# The PR body is attacker-writable, so a matching marker SHAPE is not evidence that
# the record can be carried: the producer carries a prior marker only after
# verifying its HMAC (#784/#2982), and refuses when no key is available. The rail
# therefore VERIFIES the attestation — presence of a diff= identity AND a valid
# signature — instead of trusting its shape.
GATE_KEY_RAW="${AI_REVIEW_GATE_KEY:-}"
if [ -z "$GATE_KEY_RAW" ] && [ -f "$HOME/.pi/agent/.ai-review-gate-key" ]; then
  GATE_KEY_RAW="$(cat "$HOME/.pi/agent/.ai-review-gate-key" 2>/dev/null || true)"
fi
GATE_KEY="$(printf '%s' "$GATE_KEY_RAW" | tr -d '[:space:]')"

# Can the record at the current head be RESTORED by the producer's carry-forward
# after an update? Requires a marker that is (a) shape-valid WITH a diff= identity
# and (b) authentically signed by the gate key. Mirrors the producer's own carry
# regex and signature check (record-review.sh, the carry-forward arm) — keep both in sync.
# This is a presence + authenticity test, NOT an equivalence computation: whether
# the marker's diff= still matches the live diff is the producer's decision alone.
#
# THE EQUIVALENCE PRIMITIVE IS SHARED, AND THE RAIL MUST NOT RE-IMPLEMENT IT.
# The digest the marker carries is sha256 over the NORMALIZED diff — the ONE
# implementation is `scripts/lib/diff-normalize.py` (agent-infra #1362 D1),
# used by the producer (record-review.sh) and mirrored by the consumer
# (`tortoise` .github/workflows/ai-review-gate.yml). The rail deliberately does
# NOT re-derive it: `record-review.sh` owns the equivalence decision (see the
# WHY below), and a second implementation here would be a second definition of
# "unchanged" for one cross-repo contract. The rail reads the diff= value as an
# opaque identity and cites it verbatim.
pr_has_carry_evidence() {
  local line="" text="" sig="" expect=""
  line="$(gh_ api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null \
    | grep -m1 -E "^review recorded: reviews/${PR}\\.json verdict=${RECORD_VERDICT} @ [0-9a-f]{40} diff=[0-9a-f]{64} \\(.*\\) sig=[0-9a-f]{64}$" || true)"
  [ -n "$line" ] || return 1
  [ -n "$GATE_KEY" ] || return 1
  text="${line% sig=*}"; sig="${line##* sig=}"
  expect="$(printf '%s' "$text" | openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
  [ -n "$expect" ] || return 1
  [ "$sig" = "$expect" ]
}
# WHY the FIRST matching line, and not any line: the producer's carry pins
# `diff=${DIFF_HASH}` — the LIVE diff — which is a post-update property the rail
# cannot know without computing equivalence (the producer's decision, not the
# rail's). So the rail cannot tell a stale-diff line from a live-diff one, and the
# two candidate behaviours are:
#   narrow (this one): over-block a body whose first matching line is stale;
#   wide:              accept it, call the update, and SPEND an attestation the
#                      producer then refuses to carry.
# Over-blocking is friction (recoverable, visible); spending is silent destruction
# of a fresh attestation (the 22-updated / 17-invalidated / 0-landed mode this
# guard exists to prevent). Fail-closed wins. The over-block is a DECLARED residual
# (B), retired by #1397 (content identity) — with identity on the record an update
# stops invalidating it at all.

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
  local before="$HEAD" after="" i t=0 behind=""
  case "$MERGE_STATE" in
    UNKNOWN|""|null)
      # B6/B12 — `UNKNOWN` (and a missing/null read) means GitHub cannot currently
      # determine the merge state. Reading it as "nothing to update" would certify
      # the head against a base relation nobody established, then land on it.
      # But UNKNOWN is TRANSIENT — GitHub computes mergeability lazily — so re-poll
      # a bounded number of times before refusing: a state that is merely still
      # being computed must not false-block the unit, while a genuinely
      # undetermined state still fails CLOSED.
      while [ "$t" -lt "${ATOMIC_LAND_UNKNOWN_POLLS:-5}" ]; do
        t=$((t + 1))
        sleep "$POLL"
        resolve_state
        case "$MERGE_STATE" in UNKNOWN|""|null) : ;; *) break ;; esac
      done
      case "$MERGE_STATE" in
        UNKNOWN|""|null)
          stop "the merge state of $REPO#$PR is still undetermined after $t re-poll(s) (mergeStateStatus=${MERGE_STATE:-<none>}) — refusing to certify a head whose base relation is unknown (B6/B12)" ;;
      esac ;;
  esac
  # ── the update trigger: the ENUM, OR the base-drift condition ──────────────
  # #6424's ruling applied to the TRIGGER (route, do not exempt): the rail already
  # has the signal it needs in a response it already fetches, so it fires on
  # behind_by > 0 as well as on BEHIND. A PR whose head predates a base commit that
  # a required gate leg depends on is BLOCKED (not BEHIND) and could otherwise never
  # be refreshed — see behind_by_of(). The threshold is 0 by default: any real base
  # drift is a reason to refresh, and an already-current head reports 0, which is
  # the pre-existing no-op. ATOMIC_LAND_DRIFT_TRIGGER exists only to make the
  # boundary testable; it is not a tuning knob.
  case "$MERGE_STATE" in
    BEHIND)
      # #1565 — a BEHIND head is not by itself a reason to refresh. Refresh only
      # when something REQUIRES an up-to-date branch: read that live rather than
      # assume it (see strict_of()). A PR that is positively mergeable under
      # strict=false is already landable, so moving its head buys no mergeability
      # and costs a record invalidation + a full CI run + up to 5400s of waiting.
      #
      # WHY THIS ARM AND NOT THE BASE-DRIFT ARM BELOW: the drift arm is already
      # conditional (behind_by > 0) and exists for #1533 — a BLOCKED branch whose
      # drift red could never resolve without an update. A BLOCKED PR is still
      # `mergeable: true` (no conflicts, but a red required leg), so applying this
      # predicate there would skip precisely the refresh #1533 needed. This arm is
      # where the update is UNCONDITIONAL — it fires on the enum alone — and that is
      # the blast radius measured in #1565.
      #
      # ⚠️ THE DRIFT ARM NEEDS THE SAME PREDICATE — FOR EVERY LANDABLE STATE (#7230).
      # For `CLEAN` and `UNSTABLE` every REQUIRED leg is satisfied, and `strict: false`
      # means the distance to the base is not one of them: the only thing left between
      # that PR and a merge is the drift, which nothing requires it to close. (Do NOT
      # widen this to "anything but BLOCKED" — that set carries states that are not
      # landable, which is what the fail-closed enumeration below and mutation B22
      # exist to keep out.) The drift arm refreshed there anyway, so a green,
      # correctly-attested
      # PR had its head moved for nothing — the record then died at step 3 (#1575
      # clause E, correctly) and the rail could never land it. That is the O3 shape
      # (22 updated, 17 attestations invalidated, 0 landed) and the live repro is
      # #7462 / tortoise #7230. So the landable states are held below under the same
      # positive-false `strict` + positive-`mergeable` read as the BEHIND arm.
      #
      # TWO states are landable and both are named EXPLICITLY (fail-closed: any other
      # state refreshes): `CLEAN` — every check passed — and `UNSTABLE` — the REQUIRED
      # checks passed while only NON-required ones fail or pend, which GitHub defines
      # as mergeable and which this file's own drift sweep measures at 10 of its
      # population. Holding `CLEAN` alone would have left those 10 with the same
      # non-termination. `BLOCKED` is deliberately NOT held: that is #1533, and its
      # refresh still fires — as does a conflicting (unmergeable) head, on the
      # fail-closed `mergeable` read rather than on its state name.
      #
      # ⛔ THE FAIL-SAFE GOVERNS HERE TOO. `ATOMIC_LAND_REFRESH_ALWAYS=1` restores the
      # unconditional refresh and must be checked in THIS arm as well as the BEHIND
      # one; a state-gated skip it could not override would be an un-disableable
      # misfire.
      if [ "${ATOMIC_LAND_REFRESH_ALWAYS:-0}" = 1 ]; then
        say "atomic-land: [1/4] update — mergeStateStatus=BEHIND and ATOMIC_LAND_REFRESH_ALWAYS=1 — refreshing"
      else
        local strict mergeable
        strict="$(strict_of)"
        if [ "$strict" = false ]; then
          mergeable="$(mergeable_of)"
          if [ "$mergeable" = true ]; then
            say "atomic-land: [1/4] update — mergeStateStatus=BEHIND, but branch protection does not require an up-to-date branch (strict=false, read live) and the PR is mergeable — SKIPPING the refresh: head ${HEAD:0:12}… is kept, so no head move invalidates the record and no check is invalidated (step 3 re-records here if the record is stale; the verify step below still waits for whatever is not yet terminal) (#1565)"
            return 3
          fi
          say "atomic-land: [1/4] update — mergeStateStatus=BEHIND and strict=false live, but the PR is not positively mergeable (mergeable=${mergeable:-unreadable}) — refreshing (fail-closed)"
        else
          say "atomic-land: [1/4] update — mergeStateStatus=BEHIND, strict=${strict:-unreadable} (read live) — refreshing"
        fi
      fi ;;
    *)
      behind="$(behind_by_of "$BASE" "$HEAD")"
      local drift_landable=0
      case "$MERGE_STATE" in CLEAN|UNSTABLE) drift_landable=1 ;; esac
      if [ "$drift_landable" = 1 ] && [ -n "$behind" ] && [ "$behind" -gt "${ATOMIC_LAND_DRIFT_TRIGGER:-0}" ]; then
        # #7230 — A LANDABLE HEAD MUST NOT BE PRE-EMPTED BY THE DRIFT TRIGGER.
        # Without this arm the `elif CLEAN` no-op below is UNREACHABLE whenever the
        # head is behind, so the state that is already landable is the one state
        # guaranteed to be refreshed. Same predicate, same fail-closed direction as
        # the BEHIND arm: skip only on a POSITIVE `false` strict AND a POSITIVE
        # `true` mergeable.
        if [ "${ATOMIC_LAND_REFRESH_ALWAYS:-0}" = 1 ]; then
          say "atomic-land: [1/4] update — mergeStateStatus=$MERGE_STATE with the head $behind commit(s) behind $BASE, and ATOMIC_LAND_REFRESH_ALWAYS=1 — refreshing"
        else
          local strict mergeable
          strict="$(strict_of)"
          if [ "$strict" = false ]; then
            mergeable="$(mergeable_of)"
            if [ "$mergeable" = true ]; then
              say "atomic-land: [1/4] update — mergeStateStatus=$MERGE_STATE with the head $behind commit(s) behind $BASE, but branch protection does not require an up-to-date branch (strict=false, read live) and the PR is mergeable — SKIPPING the refresh: head ${HEAD:0:12}… is kept, so no head move invalidates the record and no check is invalidated (#7230)"
              return 3
            fi
            say "atomic-land: [1/4] update — mergeStateStatus=$MERGE_STATE and strict=false live, but the PR is not positively mergeable (mergeable=${mergeable:-unreadable}) — refreshing (fail-closed)"
          else
            say "atomic-land: [1/4] update — mergeStateStatus=$MERGE_STATE with the head $behind commit(s) behind $BASE and strict=${strict:-unreadable} (read live) — refreshing"
          fi
        fi
      elif [ -n "$behind" ] && [ "$behind" -gt "${ATOMIC_LAND_DRIFT_TRIGGER:-0}" ]; then
        say "atomic-land: [1/4] update — mergeStateStatus=$MERGE_STATE (not BEHIND) but the head is $behind commit(s) behind $BASE — refreshing on BASE DRIFT"
      elif [ "$MERGE_STATE" = "CLEAN" ]; then
        say "atomic-land: [1/4] update — mergeStateStatus=CLEAN — nothing to update"
        return 3
      elif [ -z "$behind" ]; then
        # B13 (fail-closed) — an UNREADABLE distance is not proof that the head is
        # current, and the silent "up to date" read is the exact defect this arm
        # exists to close.
        #
        # ⚠️ The reason once given here — "`CLEAN` was checked above and already
        # asserts there is no divergence" — is FALSE, and #7230 is the proof: under
        # `strict: false` a head that is genuinely behind reports `CLEAN`, which is
        # the very state the drift arm above exists to catch. `CLEAN` is a statement
        # about checks and conflicts, never about distance to the base. (Pre-fix,
        # that false premise hid the drift arm entirely: `CLEAN`+`behind>0` fell
        # through to it and had its head moved for nothing.) `CLEAN` keeps its no-op
        # for the CORRECT reason, not that one: the drift arm has already decided
        # the distance for every landable state whose compare read succeeded, and
        # where it did NOT succeed a landable head still needs no refresh — under
        # `strict: false` the distance is not a requirement, and under `strict:
        # true` GitHub cannot report `CLEAN` for a stale branch (it reports
        # `BLOCKED`).
        #
        # Any OTHER state means GitHub has told
        # us something is wrong with this head and the compare API could not tell us
        # how stale it is. Stop and name it rather than proceeding on an unmeasured
        # base relation (tortoise #6210 / #6169 are the measured population).
        stop "could not measure the head/base divergence of $REPO#$PR (mergeStateStatus=$MERGE_STATE, compare API read failed) — refusing to treat a blocked head as up to date (B13)"
      else
        say "atomic-land: [1/4] update — mergeStateStatus=$MERGE_STATE, measured $behind commit(s) behind $BASE — nothing to update"
        return 3
      fi ;;
  esac
  # B5 — never SPEND an attestation the unit cannot restore. A branch update moves
  # the head and invalidates the record; the #767 carry-forward can re-bind it only
  # if the PR body carries a SIGNED marker whose `diff=` equals the live diff. With
  # no such marker (every pre-#767 record) the update is destructive with certainty,
  # and the cost is measured: a 22-PR sweep invalidated 17 fresh attestations and
  # landed 0. This is a PRESENCE test — does an identity-bearing marker exist at all
  # — NOT an equivalence computation: the producer owns the equivalence decision.
  if [ "$RECORD_HEAD" = "$HEAD" ] && ! pr_has_carry_evidence; then
    if [ -z "$GATE_KEY" ]; then
      stop "updating $REPO#$PR would invalidate the only record (${RECORD_HEAD:0:12}…) and nothing could re-mint it — no review gate key is available (AI_REVIEW_GATE_KEY or ~/.pi/agent/.ai-review-gate-key), so the carry-forward could never verify a prior marker. Nothing was merged."
    fi
    stop "updating $REPO#$PR would invalidate the only record (${RECORD_HEAD:0:12}…) and this rail could not show it would be restored — the PR carries no VERIFIABLE signed marker with a diff= identity for verdict '$RECORD_VERDICT' (a pre-#767 marker, one signed with a different key, or a line whose signature does not verify; the PR body is attacker-writable, so a matching shape is not evidence). Record the review in the current format first; then the update carries it. Nothing was merged."
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
# check-runs defaults to 30 per page (measured: 30 of 47 at a real head), so a
# count read from one page is not a verdict — a partial surface is never CLEAN.
# --paginate emits ONE result per page, so the pages are SUMMED here; a FAILED
# read stays "?" so the caller keeps waiting instead of reading an error as zero
# pending (a false terminal hands in-flight checks to the land step).
check_count() { # $1 = jq program applied to one page of check-runs
  local raw
  if ! raw="$(gh_ api "repos/$REPO/commits/$HEAD/check-runs?per_page=100" --paginate \
                        --jq "$1" 2>/dev/null)"; then
    echo "?"
    return
  fi
  printf '%s\n' "$raw" | awk '{n+=$1} END {print n+0}'
}

wait_terminal() {
  if [ "$NO_WAIT" -eq 1 ]; then
    say "atomic-land: [2/4] verify — --no-wait: admin-merge.sh's tested-head precondition decides"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "atomic-land: [2/4] verify — (dry-run) would wait up to ${WAIT_TIMEOUT}s for terminal checks"
    return 0
  fi
  say "atomic-land: [2/4] verify — waiting (≤${WAIT_TIMEOUT}s) for the checks at ${HEAD:0:12}… to be terminal"
  # B14 (#1395 item 1): the bound is WALL-CLOCK, not a poll count. The old
  # `elapsed=$((elapsed + POLL))` credited $POLL per iteration while each
  # iteration first spends TWO `gh api` round trips, so the rail outlived its own
  # documented bound (MEASURED: #5797 sat at [2/4] verify for 93 min against a
  # nominal 90) — and `--poll 0` advanced the counter by ZERO, so the bound could
  # never be reached at all and the rail looped forever while holding the PR's
  # lock and a landing slot. Both are one defect: a counter that is not a clock.
  # $SECONDS is bash's own elapsed-time counter: it removes the CLOCK's fork (the
  # `$(date +%s)` that the first cut of this fix ran every iteration) and it
  # cannot be affected by the poll interval. It does NOT remove the loop's own
  # fork: with `--poll 0`, `sleep 0` is still /bin/sleep and forks (measured ~143
  # iterations/s, against ~98k for a pure builtin loop) — that is just a busy
  # loop, bounded by the clock above, not a second way to defeat the bound.
  # Residual: like any wall clock it can step BACKWARDS on an NTP adjustment,
  # which would delay the stop rather than defeat it permanently.
  local started elapsed remaining pending completed
  started="$SECONDS"
  while :; do
    pending="$(check_count '[.check_runs[] | select(.status != "completed")] | length')"
    completed="$(check_count '[.check_runs[] | select(.status == "completed")] | length')"
    if [ "$pending" = "0" ] && [ "$completed" != "0" ] && [ "$completed" != "?" ]; then
      say "atomic-land:     checks terminal — $completed completed, 0 pending"
      return 0
    fi
    elapsed=$(( SECONDS - started ))
    if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
      stop "the checks at ${HEAD:0:12}… were not terminal within ${WAIT_TIMEOUT}s (pending=${pending}, completed=${completed}) — re-run the rail later; nothing was recorded or merged"
    fi
    # The bound was checked JUST ABOVE, so an unclamped `sleep "$POLL"` lets the
    # rail overshoot its own bound by up to a whole poll interval — MEASURED on the
    # revision before this line: `--wait-timeout 2 --poll 8` ran 10 s wall while
    # printing "waiting (≤2s)". That is the #1395 symptom again (a rail outliving
    # the bound it reports, holding the per-PR lock), so clamp the final sleep to
    # what is actually left. min(remaining, POLL) keeps polling at the requested
    # cadence while making the bound exact to within one poll of the remainder.
    # `10#` forces BASE 10. The validator and the `-ge` test above read the argument
    # as DECIMAL, while bare arithmetic reads a leading zero as OCTAL — so
    # `--wait-timeout 010` would compare as 10 but subtract as 8, and `08` is not a
    # valid octal literal AT ALL: the arithmetic error unwinds this loop SILENTLY
    # (bash 3.2), after step [1/4] has already moved the head. Same base everywhere.
    remaining=$(( 10#$WAIT_TIMEOUT - elapsed ))
    if [ "$remaining" -gt "$POLL" ]; then remaining="$POLL"; fi
    sleep "$remaining"
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
    # #1575 clause (E) is a DISTINCT cause of the SAME exit code: the artifact was
    # PROVEN unchanged and the re-bind was refused because the target head is
    # measurably red. Blaming a changed diff would send the operator hunting for a
    # change that does not exist — the same misdiagnosis class #1362 D1 fixes below.
    if grep -qF '(#1575 clause E)' "$log"; then
      err "atomic-land: the carry was REFUSED by (#1575 clause E) — the target head ${HEAD:0:12}… IS MEASURABLY RED. The lane artifact WAS proven unchanged; do NOT hunt for a diff change. Re-run the failing checks (or wait for them), then re-record."
    else
      err "atomic-land: the recorded verdict cannot be carried to ${HEAD:0:12}… — the reviewed diff CHANGED (or no prior signed evidence for it exists)."
      # #1362 D1 — a PARTIAL INSTALL is a distinct cause of the same exit code. The
      # producer computes its digest with the sibling normalizer
      # (scripts/lib/diff-normalize.py); if that file was not farmed, the producer
      # degrades to the raw pre-#1362 digest and EVERY base-only update refuses —
      # so the message above would blame a diff that did not change. Name the
      # missing file so the remedy is an install, not a re-review. Diagnostic only:
      # the rail never re-derives the digest itself (see pr_has_carry_evidence).
      DIFF_NORMALIZER_SH="$(dirname -- "$RECORD_SH")/lib/diff-normalize.py"
      if [ ! -f "$DIFF_NORMALIZER_SH" ]; then
        err "atomic-land: ⚠️ #1362: the producer's diff normalizer ($DIFF_NORMALIZER_SH) is NOT installed — the refusal above may be a partial install, not a changed artifact. Re-run pi-bootstrap/setup.sh (which farms scripts/lib/diff-normalize.py) before re-reviewing."
      fi
    fi
    err "atomic-land: a FRESH review of the new head is required; this rail cannot author one. Nothing was merged."
    rm -f "$log"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$log"
    stop "record-review.sh exited $rc — refusing to land without a record"
  fi
  # B8 — the delegated record must ACTUALLY name THIS head. A zero exit is not
  # proof: the carry-forward arm sets the recorded sha to the CURRENT head only
  # when the reviewed diff is unchanged, and `record-review.sh` fails OPEN on a
  # transient head-read failure. Re-read from disk and require the binding rather
  # than assuming it. (This is the belt-and-braces catch for a delegate that lies;
  # the decision itself stays with the script that owns the record — the rail is a
  # sequencer, not the equivalence authority.)
  read_record || {
    err "atomic-land: the record could not be re-read after the record step — refusing to land unrecorded"
    rm -f "$log"
    return 1
  }
  if [ "$RECORD_HEAD" != "$HEAD" ]; then
    err "atomic-land: the record names ${RECORD_HEAD:0:12}… but the head is ${HEAD:0:12}… — this unit has NO record for the head it would land."
    err "atomic-land: a zero exit must leave a record naming the CURRENT head (carry-forward does that only when the reviewed diff is content-unchanged). Nothing was merged."
    rm -f "$log"
    return 1
  fi
  if ! verdict_accepted "$RECORD_VERDICT"; then
    err "atomic-land: the re-read record's verdict '${RECORD_VERDICT:-<none>}' is not accepted — refusing to land (B2)"
    rm -f "$log"
    return 1
  fi
  # Cite ONLY after the binding is VERIFIED. Posting the citation before the
  # re-read publishes a claim the rail has not yet established — a delegate that
  # exits 0 without writing makes "reused verdict …" false, and a comment cannot
  # be un-posted. The citation records a VERIFIED reuse.
  if [ "$NO_CITE" -eq 0 ]; then cite_reuse "$log" "$prior"; fi
  rm -f "$log"
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
    body="$body for the content-identical (normalized) three-dot diff (\`diff=$diff\`)."
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
  # B12 — the base TIP is captured here and compared before the land. The CAPTURE
  # read must be fail-CLOSED exactly like CERT_MB above: a transient API error
  # yielding empty would otherwise leave nothing to compare against, and the
  # pre-land arm (which runs only when this is non-empty) would skip silently —
  # landing on a base the checks never covered. An unreadable tip is not a
  # licence to certify without a base binding.
  if [ -z "$CERT_BASE_TIP" ]; then
    stop "could not read the base tip of $BASE — refusing to certify without a base binding (B12)"
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
          # The next round re-enters the whole unit, but it does NOT necessarily
          # re-run the CHECKS: round 2 goes back through do_update, and wherever the
          # drift arm HOLDS the head (a landable state on a positive `strict` false
          # — #7230) no `gh pr update-branch` happens, so the check surface is never
          # re-evaluated. What IS re-established is the base BINDING: round 2
          # re-captures CERT_BASE_TIP at the advanced tip and the pre-land re-read
          # compares against THAT. Saying "the CHECK is re-run" here would assert a
          # measurement nobody took.
          say "atomic-land: re-verifying against the advanced base — another round (the reviewed diff is unchanged and the review is reused; the base BINDING is re-established — the checks are re-run only if the head is actually moved)"
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
