#!/usr/bin/env bash
# record-review.sh <pr> <head_sha> [verdict] [repo]
# Records a code-review verdict for a PR into ~/.pi/agent/reviews/<PR>.json,
# consumed by the review-enforcer merge registry gate
# (extensions/review-enforcer/index.ts, issue #138).
#
# Canonical copy — production lives at ~/.pi/agent/scripts/record-review.sh,
# refreshed from this repo copy by the pi-bootstrap/setup.sh merge-gate
# scripts farm (#562) on every sync (auto-sync at session_start / sync.sh).
# Edit THIS file; do NOT hand-edit the ~/.pi copy — setup.sh re-copies it.
# The repo copy is what CI tests (ci-main.yml script-validate).
#
# <repo> is optional (owner/name). When omitted it is auto-detected via
# GH_REPO env or `gh repo view` when run inside a git repo. The merge gate
# uses the repo field to verify PRs in ANY repo, not just the pi process cwd.
#
# --force-stale (any position): record a head_sha that is NOT the PR's
# current head. Off by default — the stale-sha guard (#2133) refuses such
# records with exit 3 because the ai-review-gate rejects them anyway.
#
# Verdicts (issue #513):
#   clean       — a code-review skill convergence recorded its clean verdict
#                 (standard/complex tiers). Never tier-guarded.
#   clean-micro — the micro-tier PROCESS verdict: micro skips the code-review
#                 skill, so its merge record certifies the micro flow
#                 (complexity:micro linked issue + pre-flight per risk tier +
#                 the #485 ≥1-dispatch floor), NOT a multi-agent review. The
#                 clean-micro tier guard below verifies the linked same-repo
#                 issue carries the complexity:micro label at record time and
#                 REFUSES (exit 4, no write) when any same-repo closing ref
#                 is a non-micro complexity:* issue. Clean verdicts make zero
#                 extra gh calls.
set -euo pipefail

# ── closing_issue_refs <text> ─────────────────────────────────────────────
# Print EVERY issue reference resolved by a closing keyword in <text>, one
# "owner/repo#num" per line, deduplicated. Mirrors check-pipeline-compliance.sh
# parse_issue_ref's accepted forms + per-ref form priority (a. full URL
# https://github.com/<o>/<r>/issues/<n> — never /pull/<n>; b. owner/repo#<n>;
# c. bare #<n> → repo = $REPO) but returns ALL refs — parse_issue_ref is
# first-ref-only, while the tier guard needs ANY-ref semantics (a PR closing
# two same-repo issues of different tiers has no single tier identity).
# Keyword class: fix(es|ed)?|close(s|d)?|resolve(s|d)? directly followed by
# the reference (so "resolves SLACK_APPROVAL_FILE" is not an issue ref).
# Top-level + guarded main below: this function is source-reachable by tests.
closing_issue_refs() {
  local text="$1" kw
  kw='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
  # a. full URLs.
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    local repo num
    repo="$(printf '%s' "$m" | tr 'A-Z' 'a-z' | grep -oE 'https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+' | sed -E 's#https://github.com/([^/]+/[^/]+)/issues/[0-9]+.*#\1#' | head -1 || true)"
    num="$(printf '%s' "$m" | grep -oE '/issues/[0-9]+$' | grep -oE '[0-9]+' | head -1 || true)"
    if [ -n "$repo" ] && [ -n "$num" ]; then
      printf '%s#%s\n' "$repo" "$num"
    fi
  done < <(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+" || true)
  # b. owner/repo#<n> (exclude the URL class already matched in (a): the
  # owner/repo pattern requires the ref to START the token — URLs carry
  # https:// before the repo so they cannot match [^/[:space:],;)]+/
  # from token start after the keyword... guard by dropping any match whose
  # token contains "/issues/").
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    case "$m" in
      *issues/*) continue ;;
    esac
    local repo num
    repo="$(printf '%s' "$m" | grep -oE '[^/[:space:],;)]+/[^/[:space:],;)]+#[0-9]+$' | cut -d'#' -f1 || true)"
    num="$(printf '%s' "$m" | grep -oE '#[0-9]+$' | tr -d '#' || true)"
    if [ -n "$repo" ] && [ -n "$num" ]; then
      printf '%s#%s\n' "$repo" "$num"
    fi
  done < <(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*[^/[:space:],;)]+/[^/[:space:],;)]+#[0-9]+" || true)
  # c. bare #<n> → repo = $REPO.
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    local num
    num="$(printf '%s' "$m" | grep -oE '#[0-9]+$' | tr -d '#' || true)"
    if [ -n "$num" ]; then
      printf '%s#%s\n' "$REPO" "$num"
    fi
  done < <(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*#[0-9]+" || true)
}

# ── main (guarded — executable when run, inert when sourced for tests) ────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
# Scan args for --force-stale (any position); everything else stays
# positional.
FORCE_STALE=0
POSITIONAL=()
for _arg in "$@"; do
  if [ "$_arg" = "--force-stale" ]; then
    FORCE_STALE=1
  else
    POSITIONAL+=("$_arg")
  fi
done
if [ "${#POSITIONAL[@]}" -gt 0 ]; then
  set -- "${POSITIONAL[@]}"
else
  set --
fi
PR="${1:?usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--force-stale]}"
SHA="${2:?missing head_sha}"
VERDICT="${3:-clean}"
REPO="${4:-}"
case "$VERDICT" in
  clean|clean-micro) ;;
  *) echo "verdict must be 'clean' (or 'clean-micro'); refusing to record '$VERDICT'" >&2; exit 2 ;;
esac
# Input validation (#2055): the ai-review-gate binds the FULL 40-char sha and
# a numeric PR — reject bad inputs up front rather than posting evidence that
# can never verify.
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "PR number must be numeric; refusing to record '$PR'" >&2; exit 2
fi
if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "head_sha must be a full 40-char hex sha (got '${SHA:0:12}…'); refusing to record" >&2; exit 2
fi
# Auto-detect repo (owner/name) when not passed explicitly. Detect BEFORE
# format-checking: an omitted repo is legal here (auto-detected), and when
# nothing is detectable the record proceeds repo-less for backward compat.
if [ -z "$REPO" ]; then
  REPO="${GH_REPO:-}"
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "repo must be owner/name (got '$REPO'); refusing to record" >&2; exit 2
fi
# ── Stale-sha guard (#2133): verify $SHA is the PR's CURRENT head ─────────
# The ai-review-gate binds the recorded FULL sha into the signed marker and
# rejects any record whose sha != the PR head at check time. tortoise PR
# #2074 recorded a stale-but-well-formed sha (…d329… vs real head …1ebe…,
# both under short prefix 4cb7e671), causing repeated gate failures that
# masqueraded as "No AI review evidence". Refuse mismatches up front unless
# --force-stale is passed. Fail-OPEN when the head cannot be fetched (a
# transient gh/API failure must not block a legitimate record); skip when no
# repo is detectable (backward compat — record as before).
if [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  CURRENT_HEAD="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)"
  # gh api prints 4xx error bodies to stdout — only a well-formed 40-hex
  # sha counts as a successful fetch; anything else fails open.
  if ! [[ "$CURRENT_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    echo "⚠️ stale-sha guard: could not fetch the current head of $REPO#$PR (gh/API failure?) — continuing fail-open; double-check the sha before relying on the gate" >&2
  elif [ "$CURRENT_HEAD" != "$SHA" ]; then
    echo "stale-sha guard: provided sha $SHA is NOT the current PR head $CURRENT_HEAD — the ai-review-gate will reject this record" >&2
    if [ "$FORCE_STALE" -ne 1 ]; then
      echo "refusing to record stale sha $SHA for $REPO#$PR — re-record with the current head ${CURRENT_HEAD:0:12}… (or pass --force-stale to override)" >&2
      exit 3
    fi
    echo "⚠️ --force-stale passed: recording stale sha $SHA anyway — the ai-review-gate will keep rejecting until re-recorded at the current head" >&2
  fi
fi

# ── Clean-micro tier guard (#513) ──────────────────────────────────────────
# clean-micro certifies the MICRO process: the linked same-repo issue must
# carry the complexity:micro label at record time. Standard/complex/complexity
# issues are never recorded clean-micro (run the code-review skill and record
# clean instead). Clean verdicts skip this guard entirely (zero extra gh
# calls). Arms:
#   (a) ≥1 same-repo closing ref carries complexity:micro and none is
#       non-micro → allow.
#   (b) ANY same-repo closing ref carries a complexity:* label ≠ micro →
#       REFUSE exit 4, NO write (qualified + legacy keys untouched; a
#       pre-existing valid record survives).
#   (c) undeterminable — repo-less / gh missing / body unreadable / no
#       closing ref / only cross-repo refs / label fetch failed / fetched
#       labels carry no complexity:* → loud warning + record proceeds
#       (fail-open: a transient gh/API failure must not block a legitimate
#       record; the warning names the unverified tier).
if [ "$VERDICT" = "clean-micro" ]; then
  if [ -z "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
    echo "⚠️ clean-micro tier guard: repo undetectable or gh missing — tier attestation UNVERIFIED (record proceeds; a non-micro linked issue should never be recorded clean-micro)" >&2
  else
    BODY="$(gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null || true)"
    [ "$BODY" = "null" ] && BODY=""
    if [ -z "$BODY" ]; then
      echo "⚠️ clean-micro tier guard: could not read the PR body of $REPO#$PR (gh/API failure or empty body?) — tier attestation UNVERIFIED (record proceeds)" >&2
    else
      # Collect same-repo closing refs (dedupe via awk; preserve order).
      REFS="$(closing_issue_refs "$BODY" | awk -F'#' 'tolower($1) == tolower("'"$REPO"'") { seen[$0]++; if (seen[$0] == 1) print }')"
      if [ -z "$REFS" ]; then
        echo "⚠️ clean-micro tier guard: no same-repo closing-issue ref found in the PR body of $REPO#$PR — tier attestation UNVERIFIED (record proceeds; body refs: $(printf '%s' "$BODY" | grep -oE '(fix(es|ed)?|close(s|d)?|resolve(s|d)?)[[:space:]]*[^[:space:],;)]*' | head -c 200 || true))" >&2
      else
        # Per-ref label fetch. A fetch failure marks THAT ref undeterminable —
        # never refuse on a failed fetch (mirrors the stale-sha fail-open).
        REFUSED=""
        MICRO_SEEN=""
        while IFS= read -r ref; do
          [ -z "$ref" ] && continue
          num="${ref##*#}"
          LABELS="$(gh api "repos/$REPO/issues/$num/labels" --jq '.[].name' 2>/dev/null || true)"
          # A failed/filtered fetch yields nothing — undeterminable ref.
          if [ -z "$LABELS" ]; then
            echo "⚠️ clean-micro tier guard: could not fetch labels of $ref — that ref is undeterminable (record proceeds unless another ref is non-micro)" >&2
            continue
          fi
          if printf '%s\n' "$LABELS" | grep -q '^complexity:micro$'; then
            MICRO_SEEN=1
            continue
          fi
          if printf '%s\n' "$LABELS" | grep -qE '^complexity:' ; then
            OFFENDING_LABEL="$(printf '%s\n' "$LABELS" | grep -E '^complexity:' | head -1)"
            REFUSED=1
            echo "❌ clean-micro tier guard: $REPO#$PR closes $ref, whose complexity label is \"$OFFENDING_LABEL\" — clean-micro certifies the MICRO process only and is REFUSED for a non-micro linked issue." >&2
            echo "   → Run the code-review skill on the current head and record clean:" >&2
            echo "   →   record-review.sh $PR <head-sha> clean $REPO" >&2
            echo "   → If the issue's tier is genuinely micro, correct its label (issue-creation: relabel complexity:micro), then re-record clean-micro." >&2
            break
          fi
          # Labels fetched but no complexity:* label → undeterminable ref.
          echo "⚠️ clean-micro tier guard: $ref carries no complexity:* label — that ref is undeterminable (record proceeds unless another ref is non-micro)" >&2
        done <<EOF
$REFS
EOF
        if [ -n "$REFUSED" ]; then
          exit 4
        fi
        if [ -z "$MICRO_SEEN" ]; then
          echo "⚠️ clean-micro tier guard: no same-repo closing ref resolved to complexity:micro — tier attestation UNVERIFIED (record proceeds)" >&2
        fi
      fi
    fi
  fi
fi

DIR="$HOME/.pi/agent/reviews"
mkdir -p "$DIR"
# #426: registry key is repo-qualified when the repo is known — PR numbers
# collide across repos (a stale DMeer #441 record in 441.json blocked
# agent-infra #441's merge). Legacy <pr>.json stays for repo-less records.
if [ -n "$REPO" ]; then
  FILE="$DIR/${REPO%/*}-${REPO#*/}-$PR.json"
  LEGACY="$DIR/$PR.json"
else
  FILE="$DIR/$PR.json"
  LEGACY=""
fi
TMP="$FILE.tmp"
if [ -n "$REPO" ]; then
  printf '{"pr":%d,"head_sha":"%s","verdict":"%s","repo":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$VERDICT" "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
else
  printf '{"pr":%d,"head_sha":"%s","verdict":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$VERDICT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
fi
mv "$TMP" "$FILE"
# Migration (#426): a legacy <pr>.json that belongs to THIS repo is
# superseded by the qualified file — remove it so stale number-keyed copies
# can't collide later. Discriminate "no repo field at all" from "unparseable":
# only a legacy record whose embedded repo EXACTLY equals $REPO is deleted;
# anything else (foreign repo, formatted JSON we can't parse, no field) is
# LEFT ALONE — never delete a file that might be another repo's data.
if [ -n "$LEGACY" ] && [ -f "$LEGACY" ]; then
  LEGACY_REPO="$(sed -n 's/.*"repo":"\([^"]*\)".*/\1/p' "$LEGACY" | head -1)"
  if [ -n "$LEGACY_REPO" ] && [ "$LEGACY_REPO" = "$REPO" ]; then
    rm -f "$LEGACY"
  fi
fi

# ── Auto-post review evidence into the PR body (#163 follow-up) ──────────
# The pipeline compliance check (c) looks for review markers in the PR
# body/commits. Real reviews were lagging the gate because nothing posted
# the evidence (PR #163 merged RED for exactly this). Append a marker line
# here, at record time. Idempotent; best-effort — NEVER fails the record.
if command -v gh >/dev/null 2>&1 && [ -n "$REPO" ]; then
  # Sign the marker (HMAC-SHA256 over the marker text, AI_REVIEW_GATE_KEY) so
  # the GitHub ai-review-gate required check cannot be satisfied by editing
  # the PR body (#2055). Key: env AI_REVIEW_GATE_KEY or ~/.pi/agent/.ai-review-gate-key.
  # Missing key → warn loudly and post UNSIGNED (the gate will fail closed).
  GATE_KEY="${AI_REVIEW_GATE_KEY:-}"
  if [ -z "$GATE_KEY" ] && [ -f "$HOME/.pi/agent/.ai-review-gate-key" ]; then
    GATE_KEY="$(cat "$HOME/.pi/agent/.ai-review-gate-key" 2>/dev/null || true)"
  fi
  # Normalize the key exactly like the workflow does (secrets arrive clean,
  # but a file/env key may carry stray whitespace).
  GATE_KEY="$(printf '%s' "$GATE_KEY" | tr -d '[:space:]')"
  # The record is written from these same args, so record and marker are
  # consistent by construction (head_sha == $SHA, verdict == $VERDICT).
  # The marker text is a SEPARATE contract from the record filename: the
  # external ai-review-gate required check regex-matches
  #   ^review recorded: reviews/<PR>.json verdict=… @ <sha> (<owner/repo>) sig=…
  # (tortoise .github/workflows/ai-review-gate.yml), so the marker KEEPS the
  # legacy-style reviews/<PR>.json reference even though the record file is
  # now repo-qualified (#426). Never rename it to match the file.
  MARKER="review recorded: reviews/${PR}.json verdict=${VERDICT} @ ${SHA} (${REPO})"
  if [ -n "$GATE_KEY" ]; then
    SIG="$(printf '%s' "$MARKER" | openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
    if [ -n "$SIG" ]; then
      MARKER="${MARKER} sig=${SIG}"
    else
      echo "⚠️ could not compute marker signature (openssl?) — posting unsigned marker; ai-review-gate will fail" >&2
    fi
  else
    echo "⚠️ AI_REVIEW_GATE_KEY not configured (env or ~/.pi/agent/.ai-review-gate-key) — posting unsigned marker; ai-review-gate required check will fail. Configure the key to match the repo secret." >&2
  fi
  # Read the PR body — distinguish a genuinely EMPTY body (post marker-only)
  # from a GET FAILURE (skip the post loudly — never clobber the description).
  if BODY="$(gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null)"; then
    [ "$BODY" = "null" ] && BODY=""
  else
    echo "⚠️ record-review: could not read PR body (transient API failure?) — evidence post skipped; record still saved. Re-run record-review.sh to retry the post." >&2
    exit 0
  fi
  # Idempotent append — post even when the body is EMPTY (an empty body must
  # not silently skip the evidence post; the gate would fail with no trace).
  # MARKER_PRESENT gates the #633 stale-run remediation below: a re-run only
  # helps once this record's signed marker is actually in the body.
  MARKER_PRESENT=1
  if ! printf '%s' "$BODY" | grep -qF "$MARKER"; then
    MARKER_PRESENT=0
    if [ -n "$BODY" ]; then
      NEWBODY="${BODY}

${MARKER}"
    else
      NEWBODY="$MARKER"
    fi
    if jq -n --arg body "$NEWBODY" '{body: $body}' 2>/dev/null \
        | gh api -X PATCH "repos/$REPO/pulls/$PR" --input - >/dev/null 2>&1; then
      MARKER_PRESENT=1
      echo "review evidence posted to $REPO#$PR body"
    else
      echo "note: could not post review evidence to PR body (record still saved)" >&2
    fi
  fi

  # ── Stale gate-run remediation (#633) ──────────────────────────────────
  # A completed pre-evidence FAILURE (the push-triggered run that evaluated
  # the body before this marker existed) does not durably block a merge once
  # a later SUCCESS for the same head exists (verified empirically, #633) —
  # but the FAILURE keeps showing a red ai-review-gate row in the rollup
  # until something re-evaluates, and when the gate's NEWEST completed run on
  # the head is red the documented remedy — "re-run record-review.sh to
  # retry" — used to be a silent no-op: the marker is already in the body, so
  # no PATCH fires, no `edited` event, and no fresh gate run (tortoise PR
  # #2698 thrashed on this for 40 min). User tokens cannot rewrite the stale
  # run's conclusion (PATCH /check-runs/{id} → 403, GitHub-App-only) nor
  # re-request it (POST /check-runs/{id}/rerequest → 404 for Actions runs),
  # but CAN re-run the Actions job (POST /actions/jobs/{id}/rerun — verified
  # #633). So when the recorded head's NEWEST completed gate run is red, re-run
  # it here: the re-run re-reads the PR body live, so with the signed marker
  # present it replaces the stale red attempt with a fresh run (for GitHub
  # Actions the check-run id IS the job id). A newer SUCCESS for the name is
  # the normal green end-state (no rerun — would just churn Actions jobs); a
  # deliberately stale record (--force-stale) is never remediated (its gate
  # state is unresolvable by design and a rerun in the PR's concurrency group
  # could cancel the real head's in-flight gate run). The gate's check-run
  # name is repo-specific — override AI_REVIEW_GATE_CHECK_NAME for consumers
  # that renamed their required check. Best-effort — NEVER fails the record.
  if [ "${MARKER_PRESENT:-0}" = "1" ] && [ "$FORCE_STALE" -ne 1 ]; then
    GATE_CHECK="${AI_REVIEW_GATE_CHECK_NAME:-ai-review-gate}"
    NEWEST_RED_ID=""
    # The commit check-runs payload is read RAW so a query failure is
    # distinguishable from "no red run" (the #405 convention: a transient
    # API failure must warn loudly and skip, never read as nothing-to-do).
    if GATE_JSON="$(gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" 2>/dev/null)"; then
      # Newest completed run for the gate check name; remediate only when its
      # conclusion is red (success/skipped/neutral satisfy the required
      # check). $gate comes via --arg — no jq-program interpolation.
      NEWEST_RED_ID="$(printf '%s' "$GATE_JSON" \
        | jq -r --arg gate "$GATE_CHECK" \
          '[.check_runs[] | select(.name == $gate) | select(.status == "completed")] | sort_by(.id) | reverse | .[0] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required") | .id' \
        2>/dev/null || true)"
    else
      echo "⚠️ could not read check runs for $SHA (gh/API failure?) — stale-run re-run skipped; record still saved. Re-run record-review.sh to retry." >&2
    fi
    # Shape-guard the id before it reaches gh argv (ids come from GitHub
    # JSON .id fields, but an errored query must never read as a job id).
    if [ -n "$NEWEST_RED_ID" ] && [[ "$NEWEST_RED_ID" =~ ^[0-9]+$ ]]; then
      if gh api -X POST "repos/$REPO/actions/jobs/$NEWEST_RED_ID/rerun" >/dev/null 2>&1; then
        echo "re-ran stale $GATE_CHECK run (job $NEWEST_RED_ID) — the fresh run re-evaluates the body with the recorded marker"
      else
        echo "note: could not re-run stale $GATE_CHECK job $NEWEST_RED_ID (permissions/state?) — record saved; the gate re-evaluates only on the next push or PR-body edit, so push a commit or re-record to retry" >&2
      fi
    fi
  fi
else
  echo "⚠️ record-review: evidence post skipped (gh CLI missing or REPO undetectable) — the record is saved, but the ai-review-gate required check will fail until evidence is posted manually." >&2
fi
fi # /main guard (#513)
