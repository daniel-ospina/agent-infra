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
  `<type>(<scope>): <subject> (#<ISSUE>)`; the body must carry `Closes #<ISSUE>` ON ITS OWN LINE (a
  mid-sentence mention does not count — check [a]) — or `Refs #<ISSUE>` if partial — plus what
  changed and exact test evidence.
- Use the research skill for non-trivial research; never call `web_search` directly.
- Never ask the human anything. File a pre-existing bug with an issue instead of fixing it silently.

<!-- BEGIN delivery-contract — drift-pinned from scripts/orchestrator-harness/reviewer-preflight.sh --delivery-brief lane; edit THERE, not here (reviewer-preflight.test.sh §G compares this block byte for byte) -->
## COMMIT AS YOU GO — a killed lane must leave a PR behind (agent-infra#2981)

**Commit as soon as you have a coherent unit, push it, then KEEP IMPROVING it.** Do not save your
work for one commit at the end. The wall clock does not warn before it fires: a lane killed at its
cap takes the uncommitted tree with it, so a lane that holds everything delivers NOTHING — its work
is indistinguishable from no work at all while it exists only in a worktree that is about to be
reaped.

MEASURED 2026-10-27/28 (agent-infra#2981): five repair lanes in one batch, all five killed at their
2400 s cap — **0 commits, 0 PRs, 144 KB of work** recovered only as rescue patch files. Not one of
them had done the wrong work. Not one of them had delivered it.

- A commit is a checkpoint, not a ceremony: commit when what you have BUILDS, or when the next thing
  you are about to write would make the tree worse. Several small commits are the deliverable; one
  perfect commit that never happens is not.
- **Open the PR as soon as the first commit is pushed**, then keep improving it — the PR
  being open is a starting line, not a finish line. Once it exists you do NOT open a second PR for
  the same work.
- **Push after every commit**, not once at the end — a commit that exists only in your worktree does
  not survive the worktree being reaped, and it is not what the merge chain reads.
- Keep working on the SAME branch once the PR exists. Do not restate the whole change in one final
  commit at the end of the run; that is the shape this rule exists to remove.

## ON RESUME — read the tree before you touch it

If you did not write the tree you just found, **read `git status` and `git diff` FIRST** — before
any edit, and before any checkout. An uncommitted tree in THIS worktree is your PREDECESSOR's work on
this same task: a lane killed at its cap leaves exactly that, and it can be tens of KB of finished,
tested work.

Adopt it: read the diff, keep what is right, finish what is unfinished, commit it. ⛔ **Never discard
it** — no `git checkout -- .`, no `git stash`, no `git clean`, no `git reset --hard` over
uncommitted work, and never "start from a clean tree". Discarding it is how the same work dies twice.
<!-- END delivery-contract -->

<!-- BEGIN landing-artifacts — drift-pinned from scripts/orchestrator-harness/reviewer-preflight.sh --landing-brief self; edit THERE, not here (reviewer-preflight.test.sh §F compares this block byte for byte) -->
## Landing artifacts — what makes this PR pass `pipeline-compliance` (agent-infra#2325)

That required check reads five things from the PR and its linked issue ([a]-[e] ARE the check's own
letters — `scripts/check-pipeline-compliance.sh` prints each failure with the skill that produces
it). Four of them are only producible while you work, so produce them as you go.

⛔ **EVIDENCE, NOT PAPERWORK — write only what you did.** The scoping comment and the review record must describe the work actually done and the code actually read. If you cannot earn a clean verdict, say so in the PR and report `BLOCKED`; never write a scoping comment for a plan you did not follow, nor record a verdict for a review nobody ran. A missing artifact is REFUSED by the gate; a fabricated one MERGES.

- **[a] the issue reference must BEGIN A LINE.** On its own line — optionally after a bullet, an
  ordered-list marker, `>`, a heading or a `- [ ]` checkbox — write `Closes #<ISSUE>` (or
  `Refs #<ISSUE>` when something genuinely stays open). A mid-sentence `(fixes #N)` does NOT
  count, and an unintended closing keyword can auto-close an issue on merge.
- **[b] the scoping comment, whose FIRST CONTENT LINE is the marker — `<!-- issue-scoping: … -->`
  (the producer is `skills/issue-scoping` for the epic/project tiers, or `skills/task-workflow-standard`
  for the task tier — the version varies (`v5.1 double diamond + verify`, `merged scope+plan`);
  only the `<!-- issue-scoping:` prefix is examined). Then the scoping content: boundaries,
  alternatives considered, the wiring table. POSITION is the contract — the check matches at column
  0, so ANY leading whitespace fails (at four columns it is also rendered as a CODE BLOCK, i.e. a
  mention, which is why the position is not merely cosmetic). Two other
  documented shapes are ALSO accepted: a leading ATX heading (`## Scope — …`) with the marker on the
  first content line after it, and the marker as the LAST line with content, set off by a blank line
  as a footer block. A marker quoted in a table, fence or discussion counts nowhere: those are
  mentions, not artifacts. READ THE THREAD FIRST: if a scoping comment already exists, ADD to it
  rather than starting over — and if its marker sits as a footer, insert ABOVE the footer BLOCK while
  KEEPING the blank line that immediately precedes the marker, because a marker with text directly
  above it is neither first-or-footer and stops being an artifact (posting a SECOND comment also
  satisfies the check; it scans every comment):
  `gh issue comment <ISSUE> --repo <OWNER/REPO> --body-file <file>`.
- **[c] the code-review record, bound to the PR's CURRENT head** — a line of exactly this shape, in
  the PR body or a commit message, naming THIS PR, THIS repo and THIS head:
  `review recorded: reviews/<PR>.json verdict=<clean|clean-micro|clean-low> @ <40-hex head sha> (<owner/repo>)`.
  **Record AFTER your last push, then RE-RECORD if the head moves** — a record bound to an older head is STALE, so a moved head must be RE-RECORDED at the new head: an
  older-head record certifies a revision that is no longer the PR, and the check refuses it. Record
  the verdict the work EARNS: `clean-micro` is refused on a non-micro issue (#513) and `clean-low` only
  on a diff whose every changed path is in the Low content-shape class (#1356), so in doubt use
  `clean`. If the PR body carries a line whose verdict is one the issue does NOT earn — a
  `verdict=clean-micro` on a non-micro issue, or a `verdict=clean-low` on a diff with a path
  outside the Low class — DELETE it after re-recording at the current head: the recorder
  APPENDS and never removes, so such a line keeps the check failing even after a fresh `clean`
  record. KEEP an older plain `verdict=clean` line: it does not fail the check (the head binding
  makes an older-head `clean` inert) and its `diff=… sig=…` fields are the signed marker
  `record-review.sh` carries forward when only the base moves, so deleting it turns a free carry
  into a re-review. The recorder's `--evidence` artifact is the PR comment
  carrying the reviewer's verdict (see the reviewer step below):
  `~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>`
- **[d] plan evidence** (`complexity:standard` / `complexity:complex` only): the PR changes a file
  under `docs/plans/*.md`, OR the scoping comment carries a `## Wiring` section (the wiring-check
  table). This is deliberately STRICTER than the check, which accepts any use of the word "wiring" —
  the safe direction. A `complexity:micro` issue is exempt from [b]-[e].
- **[e] test evidence** when the PR touches runtime code (`extensions/**`, `bin/*.js`): new or
  updated `*.test.ts` / `*.test.js` files in the diff, OR the run reported in the PR body — the
  exact command and its counts (`<N> passed`, `pytest …`, `npm test`, `VGATE PASS`, `<N>/<N>`).
  Evidence from a run taken BEFORE your last edit describes a tree you never pushed: re-run after the
  final change and report THAT run.

Two commit mechanics that fail SILENTLY (they are also in the Rules above, repeated because each has
cost a lane a whole PR): `git commit -F <message-file>` — never `-m`, where the shell executes
backticks and `$(…)` and the message is mangled with no error — and never `git add -A`; stage the
specific files you changed.
<!-- END landing-artifacts -->

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

   ⛔ **NOT INSIDE A BLOCKING TOOL CALL.** Your tool call is capped at 1800s while the rail's own
   wait ceiling is 18064s, so a HEALTHY rail still waiting on CI gets SIGTERMed mid-wait and reports
   NO verdict (agent-infra#2885: PR #2873 was cut off at 23:10:47Z and merged 4h45m later). Start it
   detached and poll instead:

   ```bash
   bash scripts/rail-run.sh start  <PR> ARGS...   # returns at once, prints the run id + log
   bash scripts/rail-run.sh status <PR> (--repo owner/repo) --run <run-id>
   ```
   `status` exits 10 running · 0 landed · 20 refused · 21 killed · 22 gone-without-verdict · 25 unknown
   (an evidence read abstained) — a run that produced NO verdict is never reported as a landing, and
   `landed` requires the PR's url to name THIS repo and THIS PR (a same-numbered PR elsewhere is not
   yours). `start` records the repo identity from `--repo` or `origin`; poll with the SAME `--repo`
   if you passed one. See `docs/ops/rail-run.md`.

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

⛔ **Never edit the PR body after recording to add or reword prose.** `record-review.sh --evidence`
verifies the review artifact; an edited body is a changed artifact the next reader cannot trust. The
one exception is deleting a stale `review recorded:` line (the [c] remedy — the recorder appends and
never removes).
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
