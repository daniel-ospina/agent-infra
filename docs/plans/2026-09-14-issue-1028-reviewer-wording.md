---
title: "#1028 — reframe the review-dispatch floor as a review, not a run — Scope & Plan"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-14
aboutSubjects: organisation-design-team, review-enforcer, commit-workflow
aboutObjects: agent-infra, issue-1028, issue-919, issue-939, issue-485
---

<!-- research-path: docs/plans/2026-09-14-issue-1028-reviewer-wording.md -->

# Plan — #1028: strike the "even a trivial one-line reviewer" clause

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Reframe the review-enforcer ≥1-dispatch floor's rationale so the dispatched reviewer must return a verdict on the diff, while keeping the floor itself unchanged.

**Team:** organisation-design-team

**Architecture:** Wording-only change across five live sites (`skills/commit-workflow/SKILL.md`, `skills/commit-workflow/workflow/01-preflight.md`, `extensions/review-enforcer/index.ts`), with the floor proven code-enforced and token-pinned. No logic, test, or gate-behavior change.

**Issue:** #1028 (complexity:standard, Level: task)
**Branch:** `fix/1028-reviewer-wording` (worktree `.worktrees/fix-1028-reviewer-wording`, from `origin/main` @ 02b50eb)
**Tier:** standard → `task-workflow-standard`
**Research-path:** justified-skip (axes low; no third-party deps; no novel pattern — internal wording + existing test infra). No external queries.

---

## Scope (double diamond)

### Confirmed problem

The `commit-workflow` review-dispatch instruction frames the mandatory ≥1-dispatch
floor (#485) as:

> Dispatch a reviewer sub-agent (even a trivial one-line reviewer). **It doesn't
> need to find issues — it just needs to have run.**

That clause reframes the review's *purpose* as "a dispatch happened" rather than
"the diff was reviewed". It is the exact shape #919 was filed against: a rule
satisfiable without the gate doing its job, so it teaches agents to dispatch a
rubber stamp and move on. This is #919's third action item; #939 deliberately
deferred it, recording the sibling phrasing as "test-pinned".

**What this is NOT:** the ≥1-dispatch floor itself is correct and stays. The
enforcer's job is to prevent a git operation at 0 dispatches.

### Pin verdict — the key deliverable (verified against the tree)

The exact phrasing is **NOT load-bearing**. The floor is enforced in pure code,
independently of any wording:

| Mechanism | Location |
|---|---|
| `let dispatchCount = 0`; reset on `session_start` | `extensions/review-enforcer/index.ts:1991`, `:1995` |
| `tool_result` increments on `task`/`subagent` | `:2255` (guard), `:2264` (`dispatchCount++`) |
| Allow path: `dispatchCount > 0 \|\| (taskSubAgent && _skipReviewGate())` | `:2205` |
| Tier read — **message selection only**, never allow/block | `:2220`–`:2225` |
| `if (tier === "micro") return { block, reason: MICRO_BLOCK_MESSAGE }` | `:2238` |
| `return { block, reason: BLOCK_MESSAGE }` | `:2243` |
| `TIER_RULE` — declarative, consumed only by the drift-pin test | `:1977` |

No production branch consults the wording. What the tests actually pin:

- **T1** (`extensions/review-enforcer/index.test.ts:1527`): `equal(blocked.reason, MICRO_BLOCK_MESSAGE)`
  (identity to the exported const — content-free) **plus** token asserts
  (`:1545`): `reason.includes("[REVIEW]") && reason.includes("docs-only")`, and
  `!reason.includes("code-review/SKILL.md")`. Both pinned tokens live in the
  **example prompt line** (`index.ts:1965`), not in the "trivial one-line" line.
- **T2** (`index.test.ts:2245`): three pins — (i) the 5-row
  `REVIEW-ENFORCER-TIER-RULE` fence drift in `01-preflight.md` (`:402`–`:412`),
  (ii) the producer-vocabulary pins in the Tier Detection block, and (iii) a
  claim-scoped `MICRO_WARN_ANTI_TOKENS` anti-token scan over all of
  `SWEPT_DOC_RELS` — which includes `01-preflight.md` **in full**. So lines
  340 / 346 / 390 are *outside* the fence, but they **are** inside the swept-doc
  anti-token scan: the real constraint on rewording them is that no
  warn-allow vocabulary may be introduced (`findMicroWarnClaims`), not the fence.
  Our rewrites introduce none.
- **T3** (`index.test.ts:2767`): source-shape tokens + `MICRO_WARN_ANTI_TOKENS`
  anti-token scan over `index.ts`. The proposed new words contain no anti-token.

**Conclusion:** #939's "the sibling phrasing is test-pinned" is imprecise — the
*content tokens* are pinned, the *phrasing* is free. Any rewrite is safe **iff**
`MICRO_BLOCK_MESSAGE` retains `[REVIEW]` + `docs-only` (from the example line)
and avoids the literal `code-review/SKILL.md`. Verified: no test/scripts assert
the strings `trivial one-line` or `just needs to have run`.

### The subtlety (must not be flattened)

At the micro/docs-only tier the gate's *actual* requirement remains only "a
dispatch happened": the enforcer is **content-free by design** (#485 F2) and the
multi-agent review gate is *skipped* at micro. Therefore:

- the floor stays **as-is in effect** (dispatchCount ≥ 1);
- the **rationale** changes from "it just needs to have run" → "it must return a
  verdict on the diff, however small".

No conflict, but the two must be *read* as distinct: the gate **counts** the
dispatch (enforcement) and the instruction states the **expected quality** of
that dispatch (a real review returning a verdict). The rewritten message says
both explicitly ("The floor counts the dispatch; …") so an agent is not left
with two surfaces that look like conflicting rules — `code-review/SKILL.md:1122-1124`
already states "the floor is deliberately content-free", and that stays correct.
Making the gate parse verdict content would contradict #485 and is out of scope.

### Alternatives considered

- **A1 (chosen):** keep the floor, rewrite the framing at the offending sites
  (+ align `01-preflight.md:397`), and **do not invent a test pin** — the pin
  verdict above shows no test/code path depends on the phrasing, so no co-change
  is required. The existing T1 content pins (`[REVIEW]`, `docs-only`) are
  preserved, so T1 stays green unmodified.
- **A1b:** additionally add a new string/anti-token pin. Rejected — pins a
  brittle contiguous phrase (or a bespoke scanner) the gate itself does not
  consume; the issue asked to co-change an *existing* pin, not to manufacture
  one. Recorded as falsifying #939's "test-pinned" premise instead.
- **A2:** make the enforcer inspect reviewer verdict content. Rejected —
  contradicts #485 F2's content-free floor, needs free-form output parsing, and
  at micro there is no verdict channel to require.
- **A3:** drop the floor at micro (pre-#485 leniency). Rejected — VGATE
  shape-exempts docs-only sets, so 0 dispatches would clear every gate; this is
  exactly the defect #485 closed.

### Boundary & stakeholders

- Out of scope: enforcing verdict *content*; historical docs.
- Affected: agents running `commit-workflow`; the review-enforcer remediation.
- **Historical docs deliberately left unchanged** (records of what was decided):
  `docs/epics/917-lean-workflow/01-analysis.md`,
  `docs/plans/2026-09-05-issue-485-micro-dispatch-policy.md`. Noted in the PR.

### Domain classification

**(not adversarial)** — instruction wording + one content-token assertion; it
does not change gate allow/block behaviour; no attacker-controlled input.

### Wiring check

No DB/API/auth/UI/external services. **Three repo files modified; one test file
re-verified unchanged:**

| Touch point | Type | Covered by |
|---|---|---|
| `skills/commit-workflow/SKILL.md` | instruction (`:95`) | this change |
| `skills/commit-workflow/workflow/01-preflight.md` | instruction (`:340`, `:346`, `:390`, `:397`) | this change |
| `extensions/review-enforcer/index.ts` | extension string (`MICRO_BLOCK_MESSAGE` `:1964`) | this change |
| `extensions/review-enforcer/index.test.ts` | test pin (T1) | **not modified** — no phrasing pin exists to co-change; T1's `[REVIEW]`/`docs-only` content pins survive |

**Sibling surfaces carrying the same micro-floor summary (verified; deliberately
left unchanged):** the offending *rationale* ("doesn't need to find issues / just
needs to have run") appears only at the 5 sites above. Four further surfaces
restate the floor as "dispatch a lightweight reviewer **naming the diff**":

| Surface | Text | Why unchanged |
|---|---|---|
| `skills/code-review/SKILL.md:1122-1124` | "…a lightweight reviewer naming the diff — a one-line 'NO ISSUES FOUND' check counts (the floor is deliberately content-free)" | Already requires a returned verdict; consistent with the new framing. |
| `skills/commit-workflow/workflow/03-code-review.md:31` | "…docs-only sets via a lightweight reviewer dispatch naming the diff" | Descriptive summary; carries no defect framing. "Naming the diff" stays correct — the new message requires naming the diff *and* returning a verdict. |
| `skills/commit-workflow/workflow/02-commit-pr.md:240` | "…a docs-only micro set dispatches a lightweight reviewer naming the diff" | Same — descriptive, no defect. |
| `extensions/review-enforcer/index.ts:1157` | merge-gate remediation: "complete the micro flow (pre-flight + a review dispatch naming the diff)" | Different gate (merge registry), not the dispatch-count floor; no defect. |

The sibling `01-preflight.md:397` (item 4 of the same "How to satisfy" block as
`:390`) **is** updated, because editing `:390` while leaving `:397` would make the
block read inconsistently.

---

## Implementation plan

### Task 1: Rewrite the framing at the offending sites

**Intent:** State what the reviewer must DO — return a verdict on the diff — so
the instruction no longer frames "a dispatch ran" as the purpose, while keeping
the ≥1-dispatch floor intact and making clear the floor only *counts* the
dispatch.
**Acceptance:** all 5 offending sites reworded + `01-preflight.md:397` aligned;
`MICRO_BLOCK_MESSAGE` still contains `[REVIEW]` and `docs-only` and no
`code-review/SKILL.md`; no anti-token introduced.
**Files:** Modify `skills/commit-workflow/SKILL.md`,
`skills/commit-workflow/workflow/01-preflight.md`,
`extensions/review-enforcer/index.ts`.

Exact rewrites:

1. `skills/commit-workflow/SKILL.md:95` —
   `- **What to do:** Dispatch a reviewer sub-agent that returns a verdict on the diff — even a one-line reviewer must state whether the diff is sound ("NO ISSUES FOUND" or a list of issues), however small the diff. The ≥1-dispatch floor is content-free by design (#485 F2) — it counts the dispatch, not the verdict — but the reviewer you dispatch is expected to review, not to rubber-stamp. Code-bearing sets satisfy the floor via VGATE's own [VGATE] verification dispatch, whose PASS is the code-set equivalent of a returned verdict; docs-only sets dispatch a lightweight reviewer naming the diff and returning its verdict.`
2. `01-preflight.md:340` (table cell) — replace
   `docs-only sets dispatch a lightweight reviewer (even a trivial one-line review counts).`
   → `docs-only sets dispatch a lightweight reviewer that returns a verdict on the diff (a one-line verdict is enough — the diff is small, not the review absent).`
3. `01-preflight.md:346` (rationale) — replace
   `so the ≥1 dispatch must come from a lightweight reviewer dispatch (even a trivial one-line review counts).`
   → `so the ≥1 dispatch must come from a lightweight reviewer dispatch that returns a verdict on the diff (a one-line verdict is enough — the floor is content-free (#485 F2) and counts the dispatch, but the dispatch is expected to be a real review, not merely a run).`
4. `01-preflight.md:390` (shell comment) — replace
   `# Even a trivial one-line review counts.`
   → `# The reviewer must return a verdict on the diff — a one-line verdict is enough.`
5. `extensions/review-enforcer/index.ts:1964` (`MICRO_BLOCK_MESSAGE`) — replace
   `"   → Docs-only sets (VGATE content-shape exempt) need a lightweight reviewer dispatch naming the diff — even a trivial one-line review counts:",`
   → `"   → Docs-only sets (VGATE content-shape exempt) need a lightweight reviewer dispatch that names the diff and returns a verdict on it — a one-line verdict is enough. The floor counts the dispatch; the dispatch is expected to be a real review that returns a verdict, not a sign-off:",`
6. `01-preflight.md:397` (item 4 of the same "How to satisfy" block as `:390`; kept
   coherent with it) — replace
   `docs-only micro sets (VGATE content-shape exempt) dispatch a lightweight reviewer naming the diff — the multi-agent code-review gate stays skipped per 03-code-review.md`
   → `docs-only micro sets (VGATE content-shape exempt) dispatch a lightweight reviewer naming the diff and returning a verdict on it (the floor counts the dispatch — content-free, #485 F2) — the multi-agent code-review gate stays skipped per 03-code-review.md`

### Task 2: Pin verdict — no co-change (falsifies #939's premise)

**Intent:** Record the key deliverable honestly: the exact phrasing is **not**
load-bearing, so there is nothing to co-change. The issue's step 3 ("co-change
the pin") is conditional on the pin being real; it is not.
**Acceptance:** the plan states that (i) the floor is code-enforced
independently of the wording, (ii) T1 pins only the content tokens
`[REVIEW]`/`docs-only` (which this change preserves), and (iii) no test or code
path asserts `trivial one-line` / `just needs to have run` — verified by grep.
The same pin verdict is carried into the PR body by Task 4.
**Files:** none — `extensions/review-enforcer/index.test.ts` is deliberately
**not** modified.

> **Implementation note (locked before code):** the exact rewrite strings are
> those in Task 1 above, which cycle-4 reviewers confirmed (i) preserve T1's
> `[REVIEW]`/`docs-only` content pins, (ii) introduce no anti-token, and
> (iii) touch no fence. Do not add a test assertion — Task 2's verdict stands.

Rationale for not co-changing: #919/#939 recorded the sibling phrasing as
"test-pinned"; the pin verdict falsifies that — the tests pin *content tokens*,
not the phrasing. Adding a new contiguous-phrase assertion would pin a string no
production code reads, turning a free-to-edit sentence into a CI-pinned one (the
very brittleness the pin verdict says does not exist). Per the issue's own
instruction, when no test or code path depends on the strings, say so explicitly
rather than invent a coupling. T1 stays green because the rewrite preserves
`[REVIEW]` and `docs-only` (the latter from the untouched example line
`index.ts:1965`).

### Task 3: Local verification

**Intent:** Prove no gate/test regressed.
**Acceptance:** every command below exits 0 / expected counts.
**Files:** none.

```
node scripts/check-skill-lint.mjs --skills-dir skills          # 123 SKILL.md files, 0 issues
npx tsx extensions/review-enforcer/index.test.ts              # 186 passed, 0 failed
npx tsx extensions/verification-gate/index.test.ts            # 314 passed, 0 failed (VGATE-SHAPE-RULE drift guard reads 01-preflight.md)
node extensions/shared/test-git-freshness.mjs                 # reads 01-preflight.md (#181 L3 section/order asserts)
npx tsx extensions/loop-enforcer/tier-config-parity.test.ts   # 52 passed, 0 failed
npx tsx extensions/loop-enforcer/termination.test.ts          # 46 passed, 0 failed
bash scripts/materialize-agents.sh --check .
bash scripts/check-pipeline-compliance.sh                     # exit 2 without PR context; run after the PR is open → expect exit 0
```

Note: the set pairs the **surface-derived** guards for the edited files with the
**task-mandated pre-existing baselines**. `01-preflight.md` is machine-read by
`verification-gate/index.test.ts` (the `#472` VGATE-SHAPE-RULE drift guard) and
`shared/test-git-freshness.mjs` — both included. The two loop-enforcer suites
read none of the edited files (they read `proportional-gates/SKILL.md`,
`code-review/SKILL.md`, and `loop-enforcer/*.ts`); they are the issue's mandated
baselines, listed to prove the shared tier config is still green, not as
surface-derived guards. `check-skill-lint` covers only files named `SKILL.md`
(recursively, 123 of them) — it is not a substitute for the `workflow/*.md`
drift guards.

### Task 4: Commit, PR, review gate

**Intent:** Land via the commit-workflow ceremony.
**Acceptance:** commit + VGATE dispatch + push + PR (ready, not draft); the PR
body carries the Task 2 **pin verdict** (floor code-enforced; phrasing not
pinned; no co-change required); clean code-review verdict recorded via
`record-review.sh`.
**Files:** none.

---

## Cycle log

- **scope-verify — cycle 1** (2 fresh verifiers: problem + solution).
  - problem-verifier: confirmed pin claims (a)–(d); 1×P2 — two citations
    inexact (guard `:2250`→`:2255`; T3 `:2778`→`:2767`). Both fixed.
  - solution-verifier: 1×P2 wiring — the same "How to satisfy" block restates
    the rule at `:397`; four sibling surfaces summarise the floor as "naming the
    diff". Incorporated: `:397` added to Task 1; siblings enumerated in Wiring
    with rationale. 1×P2 converge-quality — the proposed `includes("verdict")`
    pin was overstated/vacuous. Incorporated: replaced with a contiguous
    obligation-phrase pin (`"the dispatch must review the diff, not merely
    run"`) + honest comment stating it pins the message text, not behaviour.
  - Controller: no P0/P1 → fixes applied → re-verify.
- **scope-verify — cycle 2** (1 fresh verifier). 1×P2 — tier-read citation
  `:2227`–`:2233` was the `#516` comment, not the read; corrected to
  `:2220`–`:2225` (all other citations re-confirmed). Incorporated → re-verify.
- **scope-verify — cycle 3** — clean (`NO ISSUES FOUND`).
- **plan-review — cycle 1** (2 fresh reviewers: Structural+Efficiency, Integration).
  - Reviewer #2 (Integration): `NO ISSUES FOUND` (independently applied the
    rewrites in a scratch tree; T1/T2/T3 stayed green; inventory of 5 sites +
    4 siblings confirmed complete).
  - Reviewer #1: 1×P1 — Task 2 **invented** a contiguous-phrase pin where the
    plan's own thesis says the phrasing is not load-bearing; recommended
    dropping it and stating the "test-pinned" premise was falsified (or making
    any guard semantic rather than a brittle phrase). 2×P2 — (a) the T2 row
    under-described T2 (three pins; 340/346/390 are governed by the swept-doc
    anti-token scan, not the fence); (b) the new message asserted an obligation
    the gate cannot check without distinguishing "expected quality" from
    "counted floor".
  - Controller: all three incorporated — Task 2 replaced by a no-co-change pin
    verdict (P1); T2 row corrected (P2a); site-5 wording now states both the
    floor and the expectation, with a note on the content-free floor (P2b).
    → re-review.
- **plan-review — cycle 2** (2 fresh reviewers). Both clean of P0/P1; each 1×P2,
  converging: the Task 3 verification set was not derived from the edit surface
  — it omitted `extensions/verification-gate/index.test.ts` (the `#472`
  VGATE-SHAPE-RULE drift guard, which parses `01-preflight.md`) and
  `extensions/shared/test-git-freshness.mjs`, while including suites that read
  none of the edited files; and Task 2's acceptance named a PR-body artifact no
  task owned.
  - Controller: both incorporated — Task 3 now lists the two `01-preflight.md`
    readers with expected counts and a surface-derivation note; Task 4 owns the
    PR-body pin verdict. → re-review.
- **plan-review — cycle 3** (2 fresh reviewers). Reviewer #2: `NO ISSUES FOUND`.
  Reviewer #1: 2×P2 — the Task 3 note over-claimed "derived from the edit
  surface" while carrying baseline suites that read none of the edited files;
  and it mis-stated `check-skill-lint`'s scope (it recurses all 123 `SKILL.md`,
  not just top-level). Both incorporated (note reworded to distinguish
  surface-derived guards from mandated baselines). → re-review.
- **plan-review — cycle 4** (2 fresh reviewers). Both `NO ISSUES FOUND`.
  Reviewer #2 independently applied all 6 proposed rewrites in a scratch copy:
  `npx tsx extensions/review-enforcer/index.test.ts` = 186 passed, 0 failed;
  verification-gate 314/0; test-git-freshness 40/0; loop-enforcer 52/0 and 46/0;
  inventory confirmed complete. **plan-review: CLEAN.**
- **code-review — cycle 1** (PR #1044; 7 reviewers: 4 always-on + Skill
  Infrastructure + Ontology & Templates + Extension Safety). Clean: Guidance,
  Bug Scan, Security, Skill Infrastructure, Extension Safety.
  - Agent #3 (History/PR comments): 1×P2 — the new obligation wording
    ("must be a review") could read as contradicting the content-free floor
    stated in `code-review/SKILL.md:1124` ("the floor is deliberately
    content-free"), and the VGATE carve-out. Incorporated: the obligation sites
    (`SKILL.md:95`, `01-preflight.md:346`/`:397`) now state the floor is
    content-free (#485 F2) and that the verdict is *expected quality*, and
    `SKILL.md:95` names the VGATE PASS as the code-set equivalent of a verdict.
  - Agent #1 + #9: 2×P2 — the plan doc lacked the mandated `writing-plans`
    header (research-path comment + Goal/Team/Architecture) and the repo's
    doc front matter (`check-doc-affiliation.cjs` → "Missing front matter
    block"). Incorporated: front matter + header added.
  - Agent #2: 1×P2 — a doubled backtick in the plan doc's quoted rewrite.
    Fixed.
  - Controller: no P0/P1 → all P2s fixed → re-review (cycle 2).
- **code-review — cycle 2** — (pending)

<!-- plan-review: cycles=4, status=clean, version=2.3.0 -->
