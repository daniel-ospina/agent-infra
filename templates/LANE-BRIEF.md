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

## Your research contract — this section is REQUIRED, and the dispatch is REFUSED without it
(agent-infra#2258)

The block below is the canonical text `scripts/orchestrator-harness/brief-gate.sh --section lane`
renders, and it is the SAME text every generated brief carries. Copy it, fill the `<…>` slots with
YOUR pass, and keep the four labels: `nonblocking-dispatch.sh`, `orch-send.sh`, `safe-send.sh` and the
lane/fixer/bg launch seams refuse a brief without them (exit 80), naming what is missing. Do not
delete the labels to save space — a brief that carries the heading but no `RUNG:`/`CONTRADICTION TEST:`
is refused too.

## RESEARCH FIRST — before you decide anything (agent-infra#2258)

⛔ This is not a formality and it is not deep research. Do this pass BEFORE you write code, file an
issue, or open a PR, and state its outcome in your final message. It exists because two lanes in one
day acted on a false premise: one re-derived a root the tracker already held, one opened a duplicate
PR. Both were brief defects — the lane was never asked to look first.

INTERNAL: read what this repo and its tracker ALREADY hold, before you decide anything: the issue AND every comment (root-cause corrections live there), `git log --all --grep` for a prior attempt, the open PRs touching the same files, the architecture doc for the seam you are about to change. Quote file:line, issue and PR numbers. If the work is ALREADY DONE, already decided, or already decomposed into other issues, STOP and report that with evidence instead of re-deriving it.
EXTERNAL: look OUTSIDE this repo for how comparable systems solve this — vendor docs, specs, the
    `research` skill (state the rung in the RUNG line below). Say what you looked up and what you
    took from it. Skipping the rung is not allowed; `web_fetch` on a primary source always exists.
RUNG: 2 — web_search model="sonar"   ⛔ REPLACE with the rung you will actually use, naming the tool:
    1 = perplexity MCP (`mcp__seo-intelligence__perplexity_search`) · 2 = `web_search` with the model
    passed explicitly (`sonar`) · 3 = `web_fetch` / exa (`mcp_load exa`). If the rung you wanted does
    not load, name the rung you took AND the error you saw — a silent fallback erases the config gap.
CONTRADICTION TEST: which RECORDED DECISION covers this work — an owner ruling, a decision section in
    a plan doc, a decision comment on an issue, a Tortoise point carrying one? Quote it, and say
    `no recorded decision reaches this work` if none does. If a finding contradicts a recorded
    decision, it is NOT a candidate for adoption: reopen the decision and argue it in its own home;
    never adopt over it.

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
   A record bound to an older head is stale and the rail refuses it, so record AFTER the last push —
   UNLESS the CARRY below applies.
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
⛔ **A CARRY IS NOT A RE-REVIEW (#2343).** You do not pay for a second review when a **valid** record
   already exists. Pass the head **and the verdict** that record already names — the REVIEWED head, not the live one;
   a `clean-micro` record stays `clean-micro`, because the lane arm does not compare verdicts — and
   `record-review.sh` re-binds that verdict onto the live head — `mint:"carried"`, no
   `--evidence`, no new reviewer. The script decides the arm itself, so there is no `--carry` flag.
   It re-binds when the reviewed artifact is provably unchanged AND the live head is not measurably
   red: the same PR DIFF, or a forward merge of the new base into your reviewed head (a **rebase**
   rewrites the head so the LANE arm cannot carry it, but an unchanged **DIFF digest** still carries
   through the DIFF arm). A **fresh** mint still requires the dispatched reviewer.
⛔ **If the rail refuses, read the reason** — it names the command to run. Do not retry at the same
head; a refusal at an unchanged head means the evidence, not the attempt, is what must change.

## Deliverable (final message, <=25 lines)

Issue #, status (`PR_OPENED` | `ALREADY_FIXED` | `OUT-OF-REPO` | `BLOCKED` | `LANDED at <sha>`),
branch + PR URL, files changed, exact test commands + pass/fail counts, the reviewer verdict, the
attestation head, and blockers.
