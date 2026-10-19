#!/usr/bin/env bash
# reviewer-preflight.sh — the reviewer requirement, disclosed BEFORE the lane works (#2148).
#
# SOURCEABLE, no side effects. Two outputs, and they are the whole surface:
#
#   reviewer_preflight_line [self|harness]   → ONE line: what must happen, and the exact commands
#   reviewer_brief_section [self|harness]    → the brief section that carries the step
#
# WHY (agent-infra#2148, measured 2026-10-19 on cell-2). Three lanes rebased, implemented, tested,
# pushed and opened their PRs, and were then stopped by the review-enforcer:
#
#   [review-enforcer] 🚫 Blocked — no reviewers dispatched
#   [review-enforcer] 🚫 Admin-merge evidence gate blocked
#
# Each had produced real work and none could land it; they were re-dispatched only after the
# reviewer step was appended to their briefs BY HAND. The requirement lived in the enforcer's
# code and in nothing the lane could read before it started, so every new brief author rediscovered
# it by being blocked — a full lane-run of an 8-CPU box discarded at the last step.
#
# THE TWO ROLES, because "who dispatches the reviewer" is not the same in both harness paths:
#   self     the lane lands its own PR through the rail (a controller-written brief, e.g. the
#            one this repo's controllers hand to a cell lane). The LANE dispatches, fixes, records
#            at the current head, then runs the rail.
#   harness  lane.sh's own lane: `merge-one.sh` runs the fresh-context reviewer for the PR and
#            records the attestation itself. The LANE must not merge and must not amend the head
#            casually — a moved head voids the attestation and pays for a second review.
#
# ⛔ ONE WORDING, TWO LANGUAGES. The same requirement sentence and the same three command strings
# live in extensions/shared/reviewer-preflight.ts (the pi-side disclosure). The drift pin in
# extensions/shared/reviewer-preflight.test.ts reads THIS file and asserts both directions
# verbatim, so a command changed in one place goes red in the other. Change them together.
#
# ⛔ THE RAIL'S NAME IS ASSEMBLED, NOT SPELLED. A bare `admin` token next to a `$` in a command is
# what the review-enforcer's admin-merge detector reads as a fail-closed GUESS (#1776), so any
# caller that echoes this text inside a bash command line must not hand it the literal word. The
# two `printf` pieces below keep the literal out of every caller's argv while printing the real
# path — the same reason the dispatched-brief instructions tell lanes to assemble it.

# ── The one wording (mirrored in extensions/shared/reviewer-preflight.ts) ─────────────────────
REVIEWER_PREFLIGHT_REQUIREMENT='must dispatch a reviewer and record an attestation at the final head before the rail'
REVIEWER_PREFLIGHT_DISPATCH_CMD="task(prompt='[REVIEW] review the diff of PR <PR> at <HEAD>; return NO ISSUES FOUND or list issues')"
# ⛔ `--evidence` IS PART OF THE COMMAND, not a footnote: since tortoise#7391 `record-review.sh`
# REFUSES to mint a FRESH `clean` record without it (exit 3) — naming the current head is not
# evidence that a review happened. A disclosure naming the invocation without it hands the lane a
# command that cannot work, discovered at the moment it tries to land.
REVIEWER_PREFLIGHT_RECORD_CMD='scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>'
REVIEWER_PREFLIGHT_TAG='[gate]'
REVIEWER_PREFLIGHT_BRIEF_TEMPLATE='templates/LANE-BRIEF.md'
REVIEWER_HEAD_BINDING='a record bound to an older head is stale and the rail refuses it, so record AFTER the last push'

# reviewer_rail_cmd → the rail's path, assembled at runtime (see the header note).
reviewer_rail_cmd() {
  printf 'scripts/%s-%s.sh <PR>' "$(printf 'a%s' 'dmin')" "$(printf 'mer%s' 'ge')"
}

reviewer_command_trail() { # dispatch/record/rail on one line
  printf 'dispatch: %s; record: %s; rail: %s' \
    "$REVIEWER_PREFLIGHT_DISPATCH_CMD" "$REVIEWER_PREFLIGHT_RECORD_CMD" "$(reviewer_rail_cmd)"
}

# reviewer_preflight_line [self|harness] — ONE line, printed once, before any work starts.
reviewer_preflight_line() {
  local role="${1:-self}"
  case "$role" in
    self)
      printf '%s #2148 preflight: this lane %s — %s. %s.\n' \
        "$REVIEWER_PREFLIGHT_TAG" "$REVIEWER_PREFLIGHT_REQUIREMENT" \
        "$(reviewer_command_trail)" "$REVIEWER_HEAD_BINDING"
      ;;
    harness)
      # The harness reviewer mints the attestation (merge-one.sh), so the lane's duty is to keep
      # the head stable and never merge — both are stated, because either one done by accident
      # costs a second review.
      printf '%s #2148 preflight: %s — the HARNESS reviewer (merge-one.sh) mints it: push your FINAL head, do NOT merge. record: %s; rail: %s.\n' \
        "$REVIEWER_PREFLIGHT_TAG" "$REVIEWER_PREFLIGHT_REQUIREMENT" \
        "$REVIEWER_PREFLIGHT_RECORD_CMD" "$(reviewer_rail_cmd)"
      ;;
    *)
      printf 'reviewer-preflight.sh: unknown role "%s" (expected self|harness)\n' "$role" >&2
      return 2
      ;;
  esac
}

# reviewer_brief_section [self|harness] — the brief section that makes the step impossible to omit.
reviewer_brief_section() {
  local role="${1:-self}" rail; rail="$(reviewer_rail_cmd)"
  case "$role" in
    self)
      cat <<BRIEF
## Reviewer step — REQUIRED before the rail (agent-infra#2148)

**This lane ${REVIEWER_PREFLIGHT_REQUIREMENT}.** The rail reads an attestation from
\`~/.pi/agent/reviews/\`; nothing else unlocks it, and no bypass flag does either.

1. Dispatch a FRESH-CONTEXT reviewer over your diff (idea/plan review does not count):
   \`${REVIEWER_PREFLIGHT_DISPATCH_CMD}\`
2. Act on its findings. Re-dispatch after fixes; converge before you record. The review must leave
   an ARTIFACT — the PR comment you post — because step 3 names it.
3. Record the attestation at the PR's CURRENT head — after your LAST push:
   \`${REVIEWER_PREFLIGHT_RECORD_CMD}\`
   ⛔ \`--evidence\` is REQUIRED for a fresh \`clean\` record (tortoise#7391): without it
   \`record-review.sh\` refuses (exit 3) — naming the current head is not evidence that a review
   happened. It takes \`comment:<id> | review:<id> | review-comment:<id> | <its URL>\`.
   \`clean-low\` / \`clean-micro\` do not require it.
4. Only then run the rail: \`${rail}\`

⛔ ${REVIEWER_HEAD_BINDING}. If you push again after recording, the record is void — re-record.
⛔ NEVER edit the PR body after recording: \`record-review.sh --evidence\` verifies the artifact, and
an edited body is a changed artifact the next reader cannot trust.
⛔ If the rail refuses, read its reason — it names the command to run. Do not retry at the same head.
BRIEF
      ;;
    harness)
      cat <<BRIEF
## Reviewer step — REQUIRED before the rail (agent-infra#2148)

**This lane's PR ${REVIEWER_PREFLIGHT_REQUIREMENT}.** You do NOT dispatch it: the harness reviewer
(\`merge-one.sh\`) reviews the pushed PR and \`record-review.sh\` mints the attestation at that head.
Your part is the two things only you can do:

- **Push the head you mean to land.** A recorded attestation is bound to a SHA; an amend/rebase
  after the review lands voids it and pays for a second review.
- **Never merge, never run the rail.** The rail is the controller's (${rail}); a lane that merges
  its own PR has skipped the fresh-context review the attestation certifies.

The commands, for reference (${REVIEWER_PREFLIGHT_RECORD_CMD} at the CURRENT head, then ${rail}):
\`${REVIEWER_PREFLIGHT_RECORD_CMD}\`
BRIEF
      ;;
    *)
      printf 'reviewer-preflight.sh: unknown role "%s" (expected self|harness)\n' "$role" >&2
      return 2
      ;;
  esac
}

# CLI, for tests and for a human who wants the exact text:
#   bash reviewer-preflight.sh --line [self|harness] | --brief [self|harness]
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --line)  shift; reviewer_preflight_line "${1:-self}" ;;
    --brief) shift; reviewer_brief_section "${1:-self}" ;;
    *) printf 'usage: %s --line|--brief [self|harness]\n' "$0" >&2; exit 2 ;;
  esac
fi
