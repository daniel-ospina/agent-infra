#!/usr/bin/env bash
# record-review.sh <pr> <head_sha> [verdict] [repo]
# Records a code-review verdict for a PR into ~/.pi/agent/reviews/<PR>.json,
# consumed by the review-enforcer merge registry gate
# (extensions/review-enforcer/index.ts, issue #138).
#
# Canonical copy — production lives at ~/.pi/agent/scripts/record-review.sh.
# Keep both in sync when changing this file.
#
# <repo> is optional (owner/name). When omitted it is auto-detected via
# GH_REPO env or `gh repo view` when run inside a git repo. The merge gate
# uses the repo field to verify PRs in ANY repo, not just the pi process cwd.
set -euo pipefail
PR="${1:?usage: record-review.sh <pr> <head_sha> [verdict] [repo]}"
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
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "repo must be owner/name (got '$REPO'); refusing to record" >&2; exit 2
fi
# Auto-detect repo (owner/name) when not passed explicitly.
if [ -z "$REPO" ]; then
  REPO="${GH_REPO:-}"
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
DIR="$HOME/.pi/agent/reviews"
mkdir -p "$DIR"
TMP="$DIR/$PR.json.tmp"
if [ -n "$REPO" ]; then
  printf '{"pr":%d,"head_sha":"%s","verdict":"%s","repo":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$VERDICT" "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
else
  printf '{"pr":%d,"head_sha":"%s","verdict":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$VERDICT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
fi
mv "$TMP" "$DIR/$PR.json"

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
  if ! printf '%s' "$BODY" | grep -qF "$MARKER"; then
    if [ -n "$BODY" ]; then
      NEWBODY="${BODY}

${MARKER}"
    else
      NEWBODY="$MARKER"
    fi
    jq -n --arg body "$NEWBODY" '{body: $body}' 2>/dev/null \
      | gh api -X PATCH "repos/$REPO/pulls/$PR" --input - >/dev/null 2>&1 \
      && echo "review evidence posted to $REPO#$PR body" \
      || echo "note: could not post review evidence to PR body (record still saved)" >&2
  fi
else
  echo "⚠️ record-review: evidence post skipped (gh CLI missing or REPO undetectable) — the record is saved, but the ai-review-gate required check will fail until evidence is posted manually." >&2
fi
