#!/usr/bin/env bash
# reviewer-preflight.sh — the reviewer requirement, disclosed BEFORE the lane works (#2148).
#
# SOURCEABLE, no side effects. Four outputs, and they are the whole surface:
#
#   reviewer_preflight_line [self|harness|reviewer]  → ONE line: what must happen, and the commands
#   reviewer_brief_section [self|harness]            → the brief section that carries the step
#     (`reviewer` has no brief section by design: merge-one.sh composes that session's prompt)
#   landing_artifacts_brief_section [self|harness]   → the section that tells the lane HOW to produce
#     the artifacts `pipeline-compliance` checks ([a] issue ref, [b] scoping marker, [c] the
#     head-bound review record, [d] plan evidence); spliced into the brief by lane.sh (#2325).
#   delivery_brief_section [lane|prfix|bg]           → the section that tells a worker to COMMIT AND
#     PUSH as it goes (and to adopt, never discard, an uncommitted tree it inherited); spliced into
#     every generated brief that orders work — lane.sh, fix-one.sh, pr-doctor.py — and appended by
#     nonblocking-dispatch.sh to any authored brief that does not already carry it (#2981).
#
# ⛔ THE ROLE IS WHAT THE WORKER'S SITUATION IS, NOT WHICH SCRIPT STARTED IT. `lane` = no PR yet, so
# open one. `prfix` = ONE already-open PR that is yours. `bg` = a worker whose brief may cover MANY
# already-open PRs or none it opens itself (`ai-drainer.sh`'s multi-PR hygiene lane, and the
# dispatcher's own `bg` default), so its sentence is CONDITIONAL — it neither orders a PR into
# existence nor claims one it does not have. Handing a `bg` worker the `prfix` sentence is the same
# false-order class #2148/#2325 exist to remove (found in this PR's own review, cycle 1).
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
⛔ NEVER edit the PR body after recording to ADD or REWORD prose: \`record-review.sh --evidence\`
verifies the artifact, and an edited body is a changed artifact the next reader cannot trust. The
ONE exception is the [c] remedy — deleting a stale \`review recorded:\` line, which the recorder
appends and never removes.
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

# ── Landing artifacts (#2325) ───────────────────────────────────────────────────────────────────
# WHY (agent-infra#2325, measured 2026-10-25 on agent-infra): `pipeline-compliance` blocked 36 of the
# 40 open agent-infra PRs, and the count GREW faster than lanes could be rescued from it (33 → 36 in
# one hour). The cause is not per-PR. The dispatched brief told a lane to READ `issue-workflow` /
# `issue-scoping` and never to PRODUCE the artifacts those skills exist to create — so every lane did
# real work, opened a PR, was refused, and had its evidence retro-fitted by a human or a drain lane.
#
# ⛔ ONE HOME, AND IT IS NOT THIS FILE'S OPINION. The letters [a]-[e] are
# `scripts/check-pipeline-compliance.sh`'s OWN, and the shapes below are the shapes ITS parsers
# accept. The suite (`reviewer-preflight.test.sh` §F.4) EXTRACTS those parsers and drives them over
# this text's samples for [a], [b], [c], [d] and [e], so a shape that stops being accepted there goes
# red here. Do not restate the gate's rules; name them and give the shape. Where this text is
# STRICTER than the gate it says so ([d]'s `Wiring` heading: the gate accepts any occurrence of the
# word), because a stricter instruction can only make a PR more compliant, never less.
#
# ⛔ EVIDENCE, NOT PAPERWORK (this is the whole guard against the obvious shortcut). A brief that
# asks for these artifacts and stays silent about honesty teaches lanes to fabricate: a lane that
# cannot earn a clean verdict must say so and stop, because a missing artifact is REFUSED by the
# gate while a fabricated one MERGES. Both roles carry that paragraph verbatim.
#
# ⛔ NO TYPESCRIPT TWIN, deliberately. `extensions/shared/reviewer-preflight.ts` is the pi-side
# disclosure and has no path that renders this checklist; a second copy with no consumer would be a
# copy that drifts unobserved. If the pi side ever prints it, add the twin AND extend the drift pin
# in `extensions/shared/reviewer-preflight.test.ts` in the same change.
LANDING_ARTIFACTS_HEADING='## Landing artifacts — what makes this PR pass `pipeline-compliance` (agent-infra#2325)'
# The one sentence both roles share, so "a moved head" cannot be stated in one place and forgotten in
# the other. It is the rule that turns a finished record into a stale one (check (c)).
LANDING_HEAD_BINDING='a record bound to an older head is STALE, so a moved head must be RE-RECORDED at the new head'
LANDING_HONESTY='**EVIDENCE, NOT PAPERWORK — write only what you did.** The scoping comment and the review record must describe the work actually done and the code actually read. If you cannot earn a clean verdict, say so in the PR and report `BLOCKED`; never write a scoping comment for a plan you did not follow, nor record a verdict for a review nobody ran. A missing artifact is REFUSED by the gate; a fabricated one MERGES.'

# landing_artifacts_brief_section [self|harness] — the brief section, role-correct on [c] only.
# The artifacts a lane OWES are identical across roles; who mints the review record is not.
landing_artifacts_brief_section() {
  local role="${1:-self}" record
  case "$role" in
    self)
      record="**Record AFTER your last push, then RE-RECORD if the head moves** — ${LANDING_HEAD_BINDING}: an
  older-head record certifies a revision that is no longer the PR, and the check refuses it. Record
  the verdict the work EARNS: \`clean-micro\` is refused on a non-micro issue (#513) and \`clean-low\` only
  on a diff whose every changed path is in the Low content-shape class (#1356), so in doubt use
  \`clean\`. If the PR body carries a line whose verdict is one the issue does NOT earn — a
  \`verdict=clean-micro\` on a non-micro issue, or a \`verdict=clean-low\` on a diff with a path
  outside the Low class — DELETE it after re-recording at the current head: the recorder
  APPENDS and never removes, so such a line keeps the check failing even after a fresh \`clean\`
  record. KEEP an older plain \`verdict=clean\` line: it does not fail the check (the head binding
  makes an older-head \`clean\` inert) and its \`diff=… sig=…\` fields are the signed marker
  \`record-review.sh\` carries forward when only the base moves, so deleting it turns a free carry
  into a re-review. The recorder's \`--evidence\` artifact is the PR comment
  carrying the reviewer's verdict (see the reviewer step below):
  \`~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>\`"
      ;;
    harness)
      record="**\`merge-one.sh\` mints this record when it reviews the pushed PR** — your duty is the head: push
  the head you mean to land, then do NOT amend, rebase or push again, because ${LANDING_HEAD_BINDING}
  (and the review is paid for a second time). For reference, the command it runs is
  \`~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>\`"
      ;;
    *)
      printf 'reviewer-preflight.sh: unknown role "%s" (expected self|harness)\n' "$role" >&2
      return 2
      ;;
  esac
  cat <<BRIEF
${LANDING_ARTIFACTS_HEADING}

That required check reads five things from the PR and its linked issue ([a]-[e] ARE the check's own
letters — \`scripts/check-pipeline-compliance.sh\` prints each failure with the skill that produces
it). Four of them are only producible while you work, so produce them as you go.

⛔ ${LANDING_HONESTY}

- **[a] the issue reference must BEGIN A LINE.** On its own line — optionally after a bullet, an
  ordered-list marker, \`>\`, a heading or a \`- [ ]\` checkbox — write \`Closes #<ISSUE>\` (or
  \`Refs #<ISSUE>\` when something genuinely stays open). A mid-sentence \`(fixes #N)\` does NOT
  count, and an unintended closing keyword can auto-close an issue on merge.
- **[b] the scoping comment, whose FIRST CONTENT LINE is the marker — \`<!-- issue-scoping: … -->\`
  (the producer is \`skills/issue-scoping\` for the epic/project tiers, or \`skills/task-workflow-standard\`
  for the task tier — the version varies (\`v5.1 double diamond + verify\`, \`merged scope+plan\`);
  only the \`<!-- issue-scoping:\` prefix is examined). Then the scoping content: boundaries,
  alternatives considered, the wiring table. POSITION is the contract — the check matches at column
  0, so ANY leading whitespace fails (at four columns it is also rendered as a CODE BLOCK, i.e. a
  mention, which is why the position is not merely cosmetic). Two other
  documented shapes are ALSO accepted: a leading ATX heading (\`## Scope — …\`) with the marker on the
  first content line after it, and the marker as the LAST line with content, set off by a blank line
  as a footer block. A marker quoted in a table, fence or discussion counts nowhere: those are
  mentions, not artifacts. READ THE THREAD FIRST: if a scoping comment already exists, ADD to it
  rather than starting over — and if its marker sits as a footer, insert ABOVE the footer BLOCK while
  KEEPING the blank line that immediately precedes the marker, because a marker with text directly
  above it is neither first-or-footer and stops being an artifact (posting a SECOND comment also
  satisfies the check; it scans every comment):
  \`gh issue comment <ISSUE> --repo <OWNER/REPO> --body-file <file>\`.
- **[c] the code-review record, bound to the PR's CURRENT head** — a line of exactly this shape, in
  the PR body or a commit message, naming THIS PR, THIS repo and THIS head:
  \`review recorded: reviews/<PR>.json verdict=<clean|clean-micro|clean-low> @ <40-hex head sha> (<owner/repo>)\`.
  ${record}
- **[d] plan evidence** (\`complexity:standard\` / \`complexity:complex\` only): the PR changes a file
  under \`docs/plans/*.md\`, OR the scoping comment carries a \`## Wiring\` section (the wiring-check
  table). This is deliberately STRICTER than the check, which accepts any use of the word "wiring" —
  the safe direction. A \`complexity:micro\` issue is exempt from [b]-[e].
- **[e] test evidence** when the PR touches runtime code (\`extensions/**\`, \`bin/*.js\`): new or
  updated \`*.test.ts\` / \`*.test.js\` files in the diff, OR the run reported in the PR body — the
  exact command and its counts (\`<N> passed\`, \`pytest …\`, \`npm test\`, \`VGATE PASS\`, \`<N>/<N>\`).
  Evidence from a run taken BEFORE your last edit describes a tree you never pushed: re-run after the
  final change and report THAT run.

Two commit mechanics that fail SILENTLY (they are also in the Rules above, repeated because each has
cost a lane a whole PR): \`git commit -F <message-file>\` — never \`-m\`, where the shell executes
backticks and \`\$(…)\` and the message is mangled with no error — and never \`git add -A\`; stage the
specific files you changed.
BRIEF
}

# ── Commit as you go (#2981) ──────────────────────────────────────────────────────────────────────
# WHY (agent-infra#2981, measured 2026-10-27/28). Five repair lanes (`prfix`, all dispatched within
# ~2 minutes on one box) were each killed at their 2400 s cap: **0 commits, 0 PRs, 144 KB of work**
# that survived only as rescue patch files. The rescue worked correctly (`bg-rescue-wip.sh` wrote a
# VERIFIED patch), and that is exactly the point — a working rescue is not a delivered result. Every
# lane was holding its single commit for the end, and the end was a `kill -TERM`.
#
# The briefs those lanes received already carried the research contract (#2258), the reviewer step
# (#2148), the landing artifacts (#2325) and the push refspec (#1894) — every rule the fleet had
# already paid for — and never the cheapest one. This section is that rule: commit as soon as you
# have a coherent unit, push, get the PR open, then keep improving it.
#
# ⛔ THE SECOND HALF IS NOT A FOOTNOTE. After that batch EVERY one of the five worktrees held its
# predecessor's uncommitted work, and a resumed lane that "starts from a clean tree" (or runs
# `git checkout -- .`) throws a whole predecessor's work away — silently, with no error and nothing
# in the log. The rule above leaves committed work behind; this half is what makes the next run able
# to USE it instead of destroying it. One unit of work must not cost two full wall clocks.
#
# ⛔ ROLE-CORRECT ON ONE SENTENCE, for the reason the landing section is role-correct on [c]: a
# `prfix` worker is dispatched TO AN EXISTING PR (`pr-doctor.py` composes that brief), so ordering it
# to "open the PR" would be a FALSE instruction — the class of untruth #2148 and #2325 both exist to
# remove from a brief. `lane` opens its own PR; `prfix`/`fixer` already have one.
DELIVERY_BRIEF_HEADING='## COMMIT AS YOU GO — a killed lane must leave a PR behind (agent-infra#2981)'

# delivery_brief_section [lane|prfix|bg] — the same text for every worker that changes a tree; only
# the sentence about the PR differs. `bg` is conditional ON PURPOSE: it is the dispatcher's DEFAULT
# kind, so the worker behind it may be repairing one PR, many PRs, or opening none.
delivery_brief_section() { # delivery_brief_section [lane|prfix|bg]
  local role="${1:-lane}" open_pr
  case "$role" in
    lane)
      open_pr='**Open the PR as soon as the first commit is pushed**, then keep improving it — the PR
  being open is a starting line, not a finish line. Once it exists you do NOT open a second PR for
  the same work.' ;;
    prfix)
      open_pr='**Your PR is ALREADY OPEN — commit and push onto it, and do NOT open a second PR.**' ;;
    bg)
      open_pr='**If the work you were given already has an open PR, commit and push onto it** — and
  do NOT open a second PR for the same work.' ;;
    *)
      printf 'reviewer-preflight.sh: unknown role "%s" (expected lane|prfix|bg)\n' "$role" >&2
      return 2 ;;
  esac
  cat <<BRIEF
${DELIVERY_BRIEF_HEADING}

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
- ${open_pr}
- **Push after every commit**, not once at the end — a commit that exists only in your worktree does
  not survive the worktree being reaped, and it is not what the merge chain reads.
- Keep working on the SAME branch once the PR exists. Do not restate the whole change in one final
  commit at the end of the run; that is the shape this rule exists to remove.

## ON RESUME — read the tree before you touch it

If you did not write the tree you just found, **read \`git status\` and \`git diff\` FIRST** — before
any edit, and before any checkout. An uncommitted tree in THIS worktree is your PREDECESSOR's work on
this same task: a lane killed at its cap leaves exactly that, and it can be tens of KB of finished,
tested work.

Adopt it: read the diff, keep what is right, finish what is unfinished, commit it. ⛔ **Never discard
it** — no \`git checkout -- .\`, no \`git stash\`, no \`git clean\`, no \`git reset --hard\` over
uncommitted work, and never "start from a clean tree". Discarding it is how the same work dies twice.
BRIEF
}

# CLI, for tests and for a human who wants the exact text:
#   bash reviewer-preflight.sh --line [self|harness|reviewer] | --brief [self|harness]
#                                  | --landing-brief [self|harness] | --delivery-brief [lane|prfix|bg]
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --line)  shift; reviewer_preflight_line "${1:-self}" ;;
    --brief) shift; reviewer_brief_section "${1:-self}" ;;
    --landing-brief) shift; landing_artifacts_brief_section "${1:-self}" ;;
    --delivery-brief) shift; delivery_brief_section "${1:-lane}" ;;
    *) printf 'usage: %s --line [self|harness|reviewer] | --brief [self|harness] | --landing-brief [self|harness] | --delivery-brief [lane|prfix|bg]\n' "$0" >&2; exit 2 ;;
  esac
fi
