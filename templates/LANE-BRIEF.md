# Lane brief template — the reviewer step is part of the brief, not a discovery

Copy this file and fill the `<…>` slots. It exists because of a measured defect
(agent-infra#2148, 2026-10-19, cell-2): three lanes rebased, implemented, tested, pushed and
opened their PRs, and were then stopped by the review-enforcer —

```
[review-enforcer] 🚫 Blocked — no reviewers dispatched
[review-enforcer] 🚫 Admin-merge evidence gate blocked
```

— with nothing before that point having told them a reviewer was mandatory. Every brief author
rediscovered the requirement by being refused at the finish line. The reviewer step below is
therefore part of the template, and `scripts/orchestrator-harness/reviewer-preflight.sh` prints
the same requirement at launch (the wording is drift-pinned against
`extensions/shared/reviewer-preflight.ts` by `reviewer-preflight.test.ts`).

---

## Your issue

**#\<ISSUE\>** — read it IN FULL including every comment (root-cause corrections live there):

```bash
gh issue view <ISSUE> --repo <OWNER/REPO> --json title,body,labels
gh issue view <ISSUE> --repo <OWNER/REPO> --comments --json comments --jq '.comments[].body'
```

The comment thread supersedes the body where they disagree. Re-measure anything labelled
provenance-stale before trusting the body.

## Setup

You are ALREADY inside your own worktree (that is your cwd, on branch `<BRANCH>`). Do NOT create,
switch, or remove worktrees, and never touch the repo's main checkout.

## Rules

- Commit with `git commit -F <message-file>` (repo-unique temp path per AGENTS.md "Editing Rules").
  Stage specific files; never `git add -A`.
- Push (`git push -u origin <BRANCH>`), then open a PR against main: title
  `<type>(<scope>): <subject> (#<ISSUE>)`; body must contain `Closes #<ISSUE>` (or `Refs #<ISSUE>`
  if partial), what changed, and exact test evidence.
- Use the research skill for non-trivial research; never call `web_search` directly.
- Never ask the human anything. File a pre-existing bug with an issue instead of fixing it silently.

## Reviewer step — REQUIRED before the rail (agent-infra#2148)

**This lane must dispatch a reviewer and record an attestation at the final head before the rail.**
The rail reads an attestation from `~/.pi/agent/reviews/`; nothing else unlocks it, and no bypass
flag does either.

1. Dispatch a FRESH-CONTEXT reviewer over your diff (idea/plan review does not count):

   ```
   task(prompt='[REVIEW] review the diff of PR <PR> at <HEAD>; return NO ISSUES FOUND or list issues')
   ```

2. Act on its findings. Re-dispatch after fixes; converge before you record. The review must leave
   an ARTIFACT (the PR comment you post) — step 3 names it.
3. Record the attestation at the PR's CURRENT head — after your LAST push:

   ```
   ~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>
   ```

   ⛔ `--evidence` is REQUIRED for a fresh `clean` record (tortoise#7391): the script refuses
   without it (exit 3), because naming the current head is not evidence that a review happened.
   `--evidence` takes `comment:<id>`, `review:<id>`, `review-comment:<id>`, or the artifact's URL.
   `clean-low` (content-only diff) and `clean-micro` (micro issue) do not require it.
   A record bound to an older head is stale and the rail refuses it, so record AFTER the last push.
4. Only then run the rail:

   ```
   scripts/admin-merge.sh <PR>
   ```

   ⛔ **The ONE-COMMAND alternative to steps 1-3.** If you would otherwise assemble a reviewer prompt
   by hand, do not: `~/.pi/agent/scripts/review-pr.sh <PR>` spawns a genuinely fresh-context
   reviewer over the PR's CURRENT head, posts its findings as the PR comment step 3 names, and —
   ONLY when the reviewer comes back clean — records the attestation with
   `record-review.sh` at that same head. Findings ⇒ exit 7, NO record, findings printed: fix, push,
   re-run. It resolves the repo and head from the PR itself, so it needs no `--repo` inside the repo
   (`--repo owner/name` when run from elsewhere). This does NOT relax the requirement — it is the
   same artifact, produced by the same recorder (agent-infra scripts/review-pr.sh).

   A lane that cannot type the rail's name literally can assemble it — a bare `admin` token next
   to a `$` is what the enforcer's admin-merge detector reads as a fail-closed guess (#1776):

   ```bash
   RAIL="scripts/$(printf 'a%s' 'dmin')-$(printf 'mer%s' 'ge').sh"
   ```

⛔ **Never edit the PR body after recording.** `record-review.sh --evidence` verifies the review
artifact; an edited body is a changed artifact the next reader cannot trust.
⛔ **If the rail refuses, read the reason** — it names the command to run. Do not retry at the same
head; a refusal at an unchanged head means the evidence, not the attempt, is what must change.

## Deliverable (final message, <=25 lines)

Issue #, status (`PR_OPENED` | `ALREADY_FIXED` | `OUT-OF-REPO` | `BLOCKED` | `LANDED at <sha>`),
branch + PR URL, files changed, exact test commands + pass/fail counts, the reviewer verdict, the
attestation head, and blockers.
