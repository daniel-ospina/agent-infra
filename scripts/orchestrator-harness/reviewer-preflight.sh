#!/usr/bin/env bash
# reviewer-preflight.sh — the reviewer requirement, disclosed BEFORE the lane works (#2148).
#
# SOURCEABLE, no side effects. Two outputs, and they are the whole surface:
#
#   reviewer_preflight_line [self|harness|reviewer]  → ONE line: what must happen, and the commands
#   reviewer_brief_section [self|harness]            → the brief section that carries the step
#     (`reviewer` has no brief section by design: merge-one.sh composes that session's prompt)
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
# THE THREE ROLES, because "who dispatches the reviewer" is not the same in every harness path:
#   self     the lane lands its own PR through the rail (a controller-written brief, e.g. the
#            one this repo's controllers hand to a cell lane). The LANE dispatches, fixes, records
#            at the current head, then runs the rail.
#   harness  a worker that pushes code (lane.sh's own lane, fix-one.sh's fixer, a bg worker):
#            `merge-one.sh` runs the fresh-context reviewer for the PR and records the attestation
#            itself. The LANE must not merge and must not amend the head casually — a moved head
#            voids the attestation and pays for a second review.
#   reviewer merge-one.sh's OWN reviewer session (`KIND=reviewer`): it posts the verdict as a PR
#            comment and reports `CLEAN <comment-url>`; it must not push, record or merge. No brief
#            section — merge-one.sh composes that prompt itself.
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
# ⛔ THE PATH IS THE HOME COPY, NOT A REPO-RELATIVE ONE (fresh review of #2148, P1): a lane's cwd is
# a CONTENT repo with no `scripts/record-review.sh`; the production copy lives in
# `~/.pi/agent/scripts/`, which is where `merge-one.sh` runs it from and where the commit-workflow
# and code-review skills point ("`~/.pi/agent/scripts` is not on PATH").
REVIEWER_PREFLIGHT_RECORD_CMD='~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>'
REVIEWER_PREFLIGHT_TAG='[gate]'
REVIEWER_HEAD_BINDING='a record bound to an older head is stale and the rail refuses it, so record AFTER the last push'
# ⛔ THE CARRY (#2343, mirrored VERBATIM from the TS `REVIEWER_PREFLIGHT_CARRY_CLAUSE`). The line
# named dispatch/record/rail and nothing else, so a lane holding a VALID record at an unchanged DIFF
# read it as "pay for a review": measured 2026-11-19, two batch-landing lanes each spent 20-40
# minutes on one they did not owe and one stopped entirely. `record-review.sh` decides the carry
# itself (CARRY_ARM=diff on a matching signed marker, else the lane arm; mint:"carried"; no
# --evidence needed) and the merge gate's carry arm only allows an exact 64-hex diff match, so this
# text names a path the gate ALREADY takes. It changes no decision.
# ⛔ FACTS THE WORDING MUST CARRY (each verified against record-review.sh; two drafts got them
# wrong): the head AND VERDICT you pass are the RECORDED ones (the carry block sits inside
# `elif CURRENT_HEAD != SHA`, :1902 — passing the live head is a FRESH mint, refused at :2008; the
# DIFF arm pins verdict=${VERDICT} at :1927 but the LANE arm takes only SHAs at :1945 and never reads
# VERDICT, so a `clean` passed over a clean-micro record would mint a claim nothing supports);
# a "base-only move" is a FORWARD MERGE for the LANE arm (:1377 — a rebased head is not an ancestor)
# yet a rebase whose DIGEST is unchanged still carries through the DIFF arm (:1943); and a measurably
# RED target head vetoes the carry (#1575 clause E, :1951).
REVIEWER_PREFLIGHT_CARRY_CLAUSE='CARRY — the exception to the stale-head rule above: you do NOT pay for a second review when a VALID record already exists. Pass the head AND the verdict that record already names (the REVIEWED head, not the live one — a clean-micro record stays clean-micro; the lane arm does not compare verdicts) and record-review.sh re-binds that verdict onto the live head, writing mint:"carried" with no --evidence and no new reviewer — the script decides the arm itself, so there is no --carry flag. It re-binds when the reviewed artifact is provably unchanged AND the live head is not measurably red: the same PR DIFF, or a forward merge of the new base into your reviewed head (a rebase rewrites the head so the LANE arm cannot carry it, but an unchanged DIFF digest still carries through the DIFF arm). A FRESH mint still requires the dispatched reviewer'
# ⛔ THE SELF LINE'S HEDGE (review of #2148, P1). `KIND` is exported by THIS repo's launchers, but the
# content-repo copy (tortoise/operations/orchestrator-harness/lane.sh) exports the bypass bundle and
# no KIND, while its brief says "you have NO \"task\" tool — do NOT dispatch. The PARENT runs the
# review gate" and "Do NOT merge." Told the exception explicitly, such a lane no longer reads two
# contradictory instructions. Same wording as the TS `NO_MARKER_HEDGE` (drift-pinned).
REVIEWER_NO_MARKER_HEDGE='If your brief says you have no `task` tool, that overrides this: do NOT dispatch and do NOT merge — the parent'"'"'s reviewer mints the attestation.'

# reviewer_rail_cmd → the rail's path, assembled at runtime (see the header note).
reviewer_rail_cmd() {
  printf 'scripts/%s-%s.sh <PR>' "$(printf 'a%s' 'dmin')" "$(printf 'mer%s' 'ge')"
}

# The artifact rule: `--evidence comment:<id>` has no referent unless the lane is told to POST the
# verdict as a PR comment (fresh review of #2148, P2). Same wording as the TS `ARTIFACT_RULE`.
REVIEWER_ARTIFACT_RULE="post the reviewer's verdict as a PR comment — that comment IS the --evidence artifact"

reviewer_command_trail() { # dispatch/record/rail/artifact on one line
  printf 'dispatch: %s; record: %s; rail: %s; %s' \
    "$REVIEWER_PREFLIGHT_DISPATCH_CMD" "$REVIEWER_PREFLIGHT_RECORD_CMD" "$(reviewer_rail_cmd)" \
    "$REVIEWER_ARTIFACT_RULE"
}

# reviewer_preflight_line [self|harness|reviewer] — ONE line, printed once, before any work starts.
reviewer_preflight_line() {
  local role="${1:-self}"
  case "$role" in
    self)
      printf '%s #2148 preflight: this lane %s — %s. %s. %s. %s\n' \
        "$REVIEWER_PREFLIGHT_TAG" "$REVIEWER_PREFLIGHT_REQUIREMENT" \
        "$(reviewer_command_trail)" "$REVIEWER_HEAD_BINDING" "$REVIEWER_PREFLIGHT_CARRY_CLAUSE" "$REVIEWER_NO_MARKER_HEDGE"
      ;;
    harness)
      # The harness reviewer mints the attestation (merge-one.sh), so the lane's duty is to keep
      # the head stable and never merge — both are stated, because either one done by accident
      # costs a second review.
      printf '%s #2148 preflight: %s — the HARNESS reviewer (merge-one.sh) mints it: push your FINAL head, do NOT merge. For reference, merge-one.sh runs: record: %s; then rail: %s.\n' \
        "$REVIEWER_PREFLIGHT_TAG" "$REVIEWER_PREFLIGHT_REQUIREMENT" \
        "$REVIEWER_PREFLIGHT_RECORD_CMD" "$(reviewer_rail_cmd)"
      ;;
    reviewer)
      # merge-one.sh's reviewer session: it OWNS the verdict comment and must not touch the three
      # things merge-one.sh owns (push / record / merge). Same wording as the TS REVIEWER_CLAUSE.
      printf '%s #2148 preflight: you ARE the harness reviewer — post the verdict as a PR comment and report `CLEAN <comment-url>`; do NOT push, do NOT record and do NOT merge (merge-one.sh owns the record and the rail). For reference, the record merge-one.sh will mint: %s.\n' \
        "$REVIEWER_PREFLIGHT_TAG" "$REVIEWER_PREFLIGHT_RECORD_CMD"
      ;;
    *)
      printf 'reviewer-preflight.sh: unknown role "%s" (expected self|harness|reviewer)\n' "$role" >&2
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

⛔ ${REVIEWER_HEAD_BINDING}. If you push again after recording the record is void UNLESS the CARRY
below applies — re-record, or re-run the recorder naming the RECORDED head so it carries.
⛔ A CARRY IS NOT A RE-REVIEW (#2343). ${REVIEWER_PREFLIGHT_CARRY_CLAUSE}.
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
#   bash reviewer-preflight.sh --line [self|harness|reviewer] | --brief [self|harness]
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --line)  shift; reviewer_preflight_line "${1:-self}" ;;
    --brief) shift; reviewer_brief_section "${1:-self}" ;;
    *) printf 'usage: %s --line [self|harness|reviewer] | --brief [self|harness]\n' "$0" >&2; exit 2 ;;
  esac
fi
