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
  MARKER="review recorded: reviews/${PR}.json verdict=${VERDICT} @ ${SHA:0:12} (${REPO})"
  BODY="$(gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null || true)"
  if [ -n "$BODY" ] && ! printf '%s' "$BODY" | grep -qF "$MARKER"; then
    NEWBODY="${BODY}

${MARKER}"
    jq -n --arg body "$NEWBODY" '{body: $body}' 2>/dev/null \
      | gh api -X PATCH "repos/$REPO/pulls/$PR" --input - >/dev/null 2>&1 \
      && echo "review evidence posted to $REPO#$PR body" \
      || echo "note: could not post review evidence to PR body (record still saved)" >&2
  fi
fi
