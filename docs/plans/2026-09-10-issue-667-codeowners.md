---
title: "#667 — CODEOWNERS for the enforcement surfaces — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-667, issue-637, issue-640, issue-646, codeowners
---

# #667 — CODEOWNERS for the enforcement surfaces — Scope & Plan

## Confirmed Problem

Verified 2026-09-09/10 while landing #640 (pi 0.85.1 bump):

```
$ ls .github/CODEOWNERS
ls: .github/CODEOWNERS: No such file or directory

$ gh api repos/daniel-ospina/agent-infra/branches/main/protection \
    --jq '{reviews:.required_pull_request_reviews, checks:.required_status_checks.contexts}'
{"reviews":null,"checks":["pipeline-compliance"]}
```

There is **no owner gate on any path** and no required review of any kind.
This is not theoretical: guard `(h)` (the pi pin-lockstep tripwire) was authored
inside the very PR it guards (#640) by the agent changing the files it checks,
and a later cycle found the guard could be satisfied by a decoy line while the
gate stayed unplugged — with the fix for that being another edit to the same
file. The #637 plan records the resulting bound honestly: a test that reads repo
files cannot defend against a commit that edits the guard and the workflow
together. That residue is the class #667 addresses (who may change the checker),
complementing #646 (does a red check block a merge).

## Decisions (issue open decisions 1–4)

1. **Owner — `@daniel-ospina`.** Verified sole maintainer via
   `gh api repos/daniel-ospina/agent-infra --jq .owner.login`. No team handle is
   invented (no team has write access). **Correction (review cycle 1, #669):**
   the working assumption that CODEOWNERS "still produces a visible requested
   review" is false here — GitHub does not request a review from the PR author,
   and the sole writer authors every PR. What this PR actually delivers is the
   ownership annotation plus a reviewed, single-source path list; the visible
   requested review is *not* observable until a second writer exists (#669). The
   same finding flags that enabling "Require review from Code Owners" in a
   single-writer repo would deadlock every PR — so #646 alone is not sufficient
   to make CODEOWNERS blocking.
2. **`required_pull_request_reviews` is NOT enabled.** It is a branch-protection
   change and is out of scope for #667; recorded as a follow-up in the PR body.
   CODEOWNERS is therefore advisory now, and it stays advisory after #646:
   #646 makes a code **status check** required — it does not touch
   `required_pull_request_reviews`. Making code-owner review blocking needs (a)
   that setting enabled **and** (b) a second approving identity, because the
   sole writer cannot approve their own PR (#669). #646 is therefore neither
   necessary nor sufficient for CODEOWNERS to block. Corrected in review
   cycle 3.
3. **Path list — enforcement surfaces only**, no catch-all:
   `.github/CODEOWNERS`, `.github/workflows/`, `templates/.github/workflows/`,
   `AGENTS.md`, the pipeline gate, the pin/version/frontmatter guard family,
   `scripts/record-review.sh` **and its test** `scripts/record-review.test.sh`
   (added in review cycle 1 — it runs in `ci-main.yml:189` and guards the verdict
   writer the pipeline gate depends on), and the review-enforcer /
   verification-gate sources + tests. `docs/plans/*` is **excluded**: it is the
   artifact the gate reads (check (d)), not the gate; guarding it is docs review
   by the back door. Full table + exclusions: `docs/ops/guarded-paths.md`.
4. **Bootstrap ordering — recorded.** GitHub reads CODEOWNERS from the PR's
   *base* branch, so this file's own PR is not covered; ownership starts with
   the next PR touching a guarded path after merge.

## Plan

1. Add `.github/CODEOWNERS` (GitHub syntax: gitignore-style patterns,
   last-match-wins, one owner per line, no `!`/`[ ]`/escaped `#`). Every entry
   is an explicit `/`-anchored path — no catch-all, per the #667 non-goal.
2. Add `docs/ops/guarded-paths.md` — the single documented list (guarded paths,
   explicit non-guarded paths with reasons, and the advisory/branch-protection
   boundary). `docs/ops/*.md` is the established policy home for this repo
   (see `docs/ops/cost-config-policy.md`, `docs/ops/session-lifecycle-contract.md`).
3. Add this plan doc.
4. Verify: local syntax sanity check of every CODEOWNERS line (a throwaway
   validator: every line is `<pattern> <owner…>`, no `!`/`[ ]`, every pattern
   resolves case-sensitively via `git ls-files`, and the pattern set equals the
   §1 table); every guarded path exists in the tree;
   `bash scripts/check-workflow-actionlint.sh`; `node scripts/ci-ref-check.test.mjs`;
   `node scripts/check-doc-affiliation.cjs --files docs/ops/guarded-paths.md docs/plans/2026-09-10-issue-667-codeowners.md`
   (`--all` is red on `main` for unrelated pre-existing docs — #671).
   No workflow or branch-protection change.

## Review Cycle Log

- **cycle 1** — 3 fresh-context dispatches (code-reviewer, bug-scanner, VGATE).
  VGATE `PASS`; code-reviewer `NEEDS-FIX` **0 P0 / 0 P1 / 4 P2**; bug-scanner
  `NEEDS-FIX` **0 P0 / 0 P1 / 1 P2** — **5 distinct P2 total** (all confidence ≥ 60):
  1. Requested-review claim unverifiable with one writer → docs corrected; filed **#669**.
     *(code-reviewer, conf 65; bug-scanner, conf 60)*
  2. `.husky/pre-commit` "every check is also in CI" was false (`check-agents-materialized.sh`,
     `check-staged-skill-frontmatter.mjs` are local-only) → row rewritten with the real split.
     *(code-reviewer, conf 72)*
  3. "checked against each other" asserted a check that does not exist → reworded; drift test filed **#670**.
     *(code-reviewer, conf 68)*
  4. `scripts/record-review.test.sh` omitted while the file states "a weakened test is a weakened guard"
     → added to CODEOWNERS + §1. *(code-reviewer, conf 72)*
  5. Plan step-4 command failed as written (`check-doc-affiliation.cjs` needs `--files`) → fixed.
     *(bug-scanner, conf 95 — reported outside the code-reviewer's 4)*
- **cycle 2** — 3 fresh-context dispatches (code-reviewer, bug-scanner, VGATE).
  VGATE `PASS`; bug-scanner `NO ISSUES FOUND`; code-reviewer `NEEDS-FIX`:
  **0 P0, 0 P1, 3 P2**. All three were the cycle-1 overclaim surviving in
  files the cycle-1 fix round had missed:
  1. `.github/CODEOWNERS` still said the file "only produces review requests" /
     "it requests a review" → replaced with the ownership-ANNOTATION wording + #669.
  2. `docs/ops/guarded-paths.md` §3 "the list itself cannot change without that
     same review" → now states the list can currently change in any PR, and the
     row is advisory.
  3. `docs/ops/guarded-paths.md` §2 `docs/**` row "would request owner review on
     every plan doc" → now says it would only *attribute* the change.
- **cycle 3** — 3 fresh-context dispatches (code-reviewer, VGATE; the cycle-2
  bug-scanner scope — pattern/path resolution — was unchanged with 0 findings).
  VGATE `PASS`; code-reviewer `NEEDS-FIX`: **0 P0, 0 P1, 2 P2**. Both were
  documentation-consistency defects introduced by the earlier fix rounds:
  1. The stale "advisory until #646 lands" claim in decision 2 and the Out-of-Scope
     bullet contradicted the corrected decision-1 text → both rewritten to state
     that #646 governs required *status checks* only and is neither necessary nor
     sufficient; blocking needs the reviews setting + a second identity (#669).
  2. This Review Cycle Log was a dangling placeholder (AGENTS.md exit condition)
     and mis-attributed #669/#670 to cycle 2 → replaced with this full log.
  Fix round applied; cycle 4 re-review below.
- **cycle 4** — final fresh-context re-review (code-reviewer + VGATE). VGATE `PASS`;
  code-reviewer `NEEDS-FIX`: **1 P2** (conf 60) — this log's cycle-1 entry declared
  `4 P2` while enumerating five findings (the bug-scanner's broken-command item was
  uncounted) → count corrected to 5 P2 with per-finding provenance; other cycles'
  counts were already item-for-item. ⚠️ **Reviewer cap (4 cycles) reached — 0 open
  findings remain**; the applied fix is a count/provenance correction inside this
  log only (no claim in CODEOWNERS or `guarded-paths.md` changed), so no cycle-5
  re-dispatch was made. Final VGATE `PASS` recorded over the frozen file set.

Out-of-scope findings filed rather than absorbed: **#669** (single-writer
requested review / deadlock — found cycle 1, confirmed cycles 2–3),
**#670** (doc↔CODEOWNERS drift test — cycle 1), **#671**
(`check-doc-affiliation.cjs --all` red on `main` — cycle 1 bug-scanner),
**#672** (agent-infra's own pre-commit hook never runs; `npx lint-staged` has
no config — cycle 1 verification).

## Out of Scope / Accepted Residual Gaps

- Enabling `required_pull_request_reviews` (branch protection) is out of scope
  and is **not** #646: #646 covers required *status checks* only. CODEOWNERS
  cannot become blocking until that setting is enabled **and** a second
  approving identity exists (a single-writer repo deadlocks otherwise) —
  tracked as **#669**. Noted in the PR body as the follow-up.
- Reviewing docs/content paths generally (explicit #667 non-goal).
- `extensions/sequence-enforcer/**`, dependency manifests inside the guarded
  extension dirs, `sync-ci-workflows.sh` and friends, and `.husky/pre-commit`
  are deliberately unguarded — reasons table in `docs/ops/guarded-paths.md` §2.
- A doc↔CODEOWNERS drift test is **not** added here (no new CI surface in a
  chore PR); the matching is verified by inspection/probe in this PR and is
  filed as **#670**.
- CODEOWNERS cannot produce a visible requested review while the sole owner
  authors every PR, and required code-owner review would deadlock a single-writer
  repo → **#669** (not #646, which covers required *status checks* only).
- Unrelated pre-existing findings filed while verifying: **#671**, **#672**.
