<!-- research-path: docs/plans/2026-10-26-workflow-redesign-proposal.md#2-research-provenance-internal--external-declared -->

# Workflow redesign — proposal (owner rulings 2026-10-26) — Implementation Plan

> **For Pi:** design proposal. Owner reviews this **before** it governs anything. §11 is the sequenced landing; §12 is what this PR does and does not change.

**Goal:** cut the issue pipeline from 6 stages / 3 blocking pre-code review rounds to 4 stages / 1, by putting the cost where the defects actually are — a **research gate on an artifact the lane produces**, a **review scope contract** in place of short cycle caps, and a **discipline router** so a reviewer is asked the questions its artifact's canon asks.

**Team:** organisation-design-team
**Issue:** agent-infra#2861

**Architecture:** two moves. (1) **Delete the loops that exist to *make* decisions** and put one enforced gate where decisions are actually lost — before planning. (2) **Invert the enforcement posture**: a load-bearing rule becomes a check on a **repo artifact read by CI**, never a paragraph in a skill, because a skill read is not compliance (a read from a *previous session* satisfies the existing read gate — `enforcement/dangerous-ops.txt` header, `READ_PERSIST_TTL_MS = 24 h`) and because a host can have no skills at all (agent-infra#9560: `operations/skills/*` = 98/98 dangling, `~/.pi/agent/skills` empty on the cells).

---

## 1. What is actually there today (measured, not recalled)

A `complexity:standard` `Level: task` issue runs:

| # | Stage | Gate | Where |
|---|---|---|---|
| 1 | ROUTE | Gate 0 (A/B), level, O/I/T *warn*, label lifecycle, collision pre-flight, branch + worktree | `skills/issue-workflow/SKILL.md` |
| 2 | SCOPE (double diamond) | verify: **problem-verify** (§2.5) + **solution-verify** (§5.5), each with "re-dispatch all verifiers" | `skills/issue-scoping/SKILL.md:157-441` |
| 3 | SCOPE-VERIFY | verify: "the tier's scope verifier(s) — count per `issue-scoping` §Tier Scaling" | `skills/task-workflow-standard/SKILL.md` |
| 4 | PLAN | `plan-review` cycle loop (reviewers per `proportional-gates` §Review Cycles) | `skills/plan-review/SKILL.md` |
| 5 | PLAN-VERIFY | verify | `skills/task-workflow-standard/SKILL.md` |
| 6 | IMPLEMENT → VERIFY | verify | `skills/task-workflow-standard/SKILL.md` |
| 7 | COMMIT | pre-flight → PR → `code-review` panel (A–E) → merge rail + head-bound attestation | `skills/commit-workflow`, `skills/code-review`, `scripts/admin-merge.sh` |

**The redundancy is in stages 2–5.** §Tier Scaling owns the verifier *counts* for problem-verify and solution-verify; SCOPE-VERIFY then dispatches "the tier's scope verifier(s)" — the same counts, over the same artifact. So a standard task pays **three** blocking review rounds before any code exists (problem-verify, solution-verify, plus SCOPE-VERIFY), then plan-review's loop on top. A `micro` task pays `full-diamond-verify` plus SCOPE-VERIFY.

**The research is prose in three places and nothing reads it.** `issue-scoping` Phase 1.5 (`### Axis Research`), `writing-plans` Step B (`### Pattern Research`), and the plan doc's `<!-- research-path: … -->` header — which `writing-plans/workflow/04-draft-plan.md:47` describes as "a back-reference for `plan-review` and other downstream skills". No check validates that the artifact exists, that it has internal *and* external sources, or that any plan decision depends on it. `origin/main:skills/planning/shared/research/SKILL.md:28` stated the gap in one line — **"No standalone research stage"** — and this PR rewrites that row at the same file, so the quote is the **pre-change** state, cited by base commit.

**What is enforced today is artifact-shaped, not skill-shaped.** `scripts/check-pipeline-compliance.sh` (a real CI gate) checks five artifacts: (a) linked issue, (b) a `<!-- issue-scoping:` comment marker, (c) a review record bound to the PR's **current head**, (d) **plan evidence — a `docs/plans/*.md` change *or* a case-insensitive `wiring` mention in the issue's comments**, (e) test evidence. That is the whole enforced pipeline, and it is the right shape — it survives a host with no skills. The skills route work into those five artifacts and nothing more.

**Skills are not gates, and the mechanism that could gate them is unarmed for these skills.** On this box 46 extensions are deployed, including `extensions/skill-enforcer.ts` (55 KB) which hard-blocks git/MCP operations until a named skill is read. Its manifest, `enforcement/dangerous-ops.txt`, carries **6 rules** — `commit-workflow` (×2), `using-git-worktrees`, `supabase`, `how-to-use-tortoise` (×2). **No rule names `issue-workflow`, `task-workflow-standard`, `issue-scoping`, `plan-review` or `code-review`.** So the fleet's finding is right about these skills specifically, and the fix is a manifest entry, not new machinery — but see §7: for *these* skills a read gate is strictly weaker than an artifact gate.

---

## 2. Research provenance (internal + external, declared)

**PREFLIGHT (research skill §Step 0.0):** `Search tool: web_search model=sonar — rung 1 unavailable (mcp_load seo-intelligence → "Unknown MCP server 'seo-intelligence'") — queries: 4 attempted / 3 returned`. The two queries issued in one batch returned 1 of 2 (HTTP 429 rate limit on the design-doc query); it was **re-issued once after a 20 s pause and returned**, so the evidence set below is complete for the four questions asked. Internal sources were read from this checkout, not recalled.

| Question | Internal evidence | External evidence |
|---|---|---|
| Does broad review produce useful findings, or noise? | Fleet measurement 2026-10-26: what caught defects was **fresh-context review at the exact head** (two "fixed" claims that had never landed) and **mutation proof** (an unpinned fail-closed branch; a deleted reconcile arm left sibling tests green) — neither is a breadth property | Microsoft, *Characteristics of Useful Code Reviews* (1.5M comments, 5 projects): larger changes touching more files receive a **lower proportion** of valuable comments. ICSE 2013 *Expectations, Outcomes and Challenges of Modern Code Review*: defect comments are a **small proportion** of review feedback |
| Does missing/wrong research cause the expensive failures? | The owner's own three duplicate-work incidents (#2985 vs PR #3005, #2952 vs PR #3018, #3061); orchestrator briefs pre-empting the research step (fleet finding 2026-10-26) | *Analyzing and Mitigating Cost-Inefficient Behaviors in Coding Agents* (arXiv 2609.30725): redundant retrieval, repeated script generation and test re-execution occur on **79–98 %** of tasks, up to **22.75 %** of task cost |
| Is spending more cycles the way to finish the hard ones? | `proportional-gates` §Review Cycles already caps at 3/5/10, and `code-review` already **removed** `max_fix_cycles` ("no cycle cap — convergence-gated instead") | *Kozuchi Agent* (arXiv 2608.15579): 80 % of resolved instances finish within 653 calls; reaching 99 % costs 1,547 — **diminishing returns**. *Agentic AI in the SDLC* (arXiv 2604.26275): verification is the bottleneck; recommends **selective** depth, "rather than treating every review stage as equally valuable" |
| Is an up-front design/research gate worth its cost? | `issue-scoping` already declares `### Adversarial Threat Surface` and bounds that domain by **coverage**, not by count — the mechanism this proposal generalizes | *Improving Design Reviews at Google* (141,652 approved documents): a structured review approach cut **median approval time by 25 %**. Baum et al. survey: **90 %** of teams review a *change*, not a module — change-scoped review is the practice |

**What the external evidence does *not* support, stated plainly:** no study measures "number of pre-code verifier rounds" as a predictor of quality. The case for 3 → 1 rests on the *internal* redundancy (§1) plus the general finding above that breadth is not where usefulness lives. It is a design judgement, and §13 names how to falsify it.

---

## 3. The stage list (after)

```
RESEARCH ──▶ PLAN ──▶ [PLAN-VERIFY] ──▶ BUILD ──▶ [PROVE]
   │            │            │                        │
 gate:        declares     gate: one               gate: typecheck +
 artifact     the SCOPE    verifier round,         tests + mutation @
 checked      CONTRACT     covering the plan       the exact head
 (CI)                      AND research-to-validate
```

4 stages, 3 gates, **1 blocking pre-code review round**. Mapping from today:

| Today | After |
|---|---|
| SCOPE (2 diamonds) + SCOPE-VERIFY + PLAN + plan-review + PLAN-VERIFY | **PLAN** (both diamonds' questions are fields of one artifact) + **one PLAN-VERIFY** |
| research prose in 3 places, unread | **RESEARCH** stage with a checked artifact (before PLAN) |
| — | **research-to-validate**, a question inside PLAN-VERIFY (§5) |
| IMPLEMENT + VERIFY | **BUILD** + **PROVE** (unchanged except mutation proof is named) |
| lean path: none | **decided-ruling path** (`issue-workflow` §Decided-ruling path, implemented in `task-workflow-standard` §Decided-ruling path) |

**Proportional depth is unchanged in kind.** Standard = 1 verifier; complex = 2 (`issue-scoping` §Tier Scaling keeps owning counts as *depth*, not as extra *rounds*). What disappears is the second and third *round* over the same artifact.

**Micro is unchanged:** no research gate, no PLAN-VERIFY, one `full-diamond-verify`. A micro lane already pays least, and the cap in `record-review.sh` already refuses `clean-micro` on gate surfaces (`proportional-gates` §Review Cycles, SURFACE CAP).

---

## 4. The research gate — artifact, contents, and how it is checked

**Artifact:** one `### Targeted Research Findings` block, posted as **its own comment** on the issue — separate from the plan comment, because `check-pipeline-compliance.sh` requires `<!-- issue-scoping:` at the first content line (or as a blank-line-set-off footer) of *its* comment, and two markers cannot both occupy that position. It reuses the existing output contract (`skills/planning/shared/research/SKILL.md` §Output Contract) — heading, `> **Findings date:**`, `## Raw Notes` — and adds the three fields that make it checkable rather than merely present:

```markdown
<!-- research: v1 -->
### Targeted Research Findings
> **Findings date:** 2026-10-26
**Search:** rung 2 (`web_search sonar`) — 4 attempted / 3 returned (1 query re-issued after 429)

**Internal** (≥1, each with a locator **and its quoted line**):
- `skills/issue-scoping/SKILL.md:31` — "🛡️ problem-verify — verifiers check diamond quality (Standard+Complex; count per Tier Scaling)" → that skill declares two verifier gates of its own, which the merge removes …
**External** (≥1, each with a URL):
- https://arxiv.org/html/2609.30725v1 → redundant retrieval on 79–98 % of tasks …

**Decisions this supports:** R1 single merged gate; R2 research before planning.
**FALSIFIER:** if a merged PLAN-VERIFY lets a wrong problem definition reach BUILD in ≥1 of
  the first 5 standard lanes, the merge is wrong and the second diamond gate is restored.
**Gaps (unanswered → carried as plan risk):** no measurement of verifier round-count vs defect escape.

## Raw Notes
- 2026-10-26T16:10Z [internal] …
```

**Checked by** `scripts/check-pipeline-compliance.sh` — the existing CI gate, in **step 2** (§11):

| Field | Check | On failure |
|---|---|---|
| marker present | `<!-- research: v1 -->` in an issue comment, at the first content line | **blocked**, naming the artifact and the producing skill |
| internal locator | ≥1 `path:line`, `#N`, or `owner/repo#N` — **and it must RESOLVE**: the path exists at the PR head, the line number is ≤ the file's line count, and the **quoted line matches** the cited line and carries the token the finding names | blocked |
| external citation | ≥1 `http(s)://` | blocked |
| findings date | `> **Findings date:** YYYY-MM-DD` | blocked |
| falsifier | non-empty `FALSIFIER:` line naming an observation **and** a consequence | blocked |
| gaps | a `Gaps:` line (may be `none`, stated) | blocked |
| tier | `complexity:micro` → skipped; decided-ruling path → `**Basis:**` must resolve to a real `owner/repo#N`, Tortoise point, or `docs/plans/*.md#section`, and `FALSIFIER:`/`Gaps:` are still required | blocked |

**The shape rule has no machine check until step 2, and this design's own first artifact broke it.** Issue #2861's initial plan comment carried `<!-- issue-scoping:` on line 1 *and* `<!-- research: v1 -->` on line 22 — one comment with two markers, which the `check-pipeline-compliance.sh` half will reject once it lands. It has been split into two comments. Until step 2 the two-comment shape is a **reviewer check, not a machine one** — said here rather than left for a lane to discover at the gate.

**Why this shape, and not "do research thoroughly":**

1. **It is the only shape that survives a pre-empted lane.** A brief that already contains the research (measured: the orchestrator's briefs were replacing the workflow) cannot satisfy a check on a comment the *lane* posts. **But presence alone is a lint**, and a reviewer of the first draft showed why: a lane can type a real path, a real URL, "today" and a plausible falsifier in twenty seconds and still plan on a false premise. **The field that carries the weight is the *resolution* of the internal locator** — a `path:line` the checker opens, whose **quoted line** says what the claim says — because that is the one thing a lazy or pre-empted lane cannot cheaply fabricate. Requiring the quote at write time (rather than only at review) moves that catch before a verifier is spent: the residue a reviewer must still judge is **bearing** — a citation that resolves and is about the neighbouring claim — and that is one judgement, made by Q2 on the same round. `FALSIFIER:` is second, and only if it names an observation *and* a consequence. `External URL`, `Findings date` and `Gaps` carry almost no weight: they are kept for the reader, not as controls, and the design says so rather than pretending otherwise.
2. **It survives a host with no skills** (cell finding #9560): the check runs in CI, from the repo being merged. A cell lane with 0/46 extensions and an empty `~/.pi/agent/skills` still cannot merge without the marker.
3. **It costs no reviewer dispatch.** It is a regex in a gate that already runs, not a review round. That is deliberately why it earns a *gate* and not a stage of its own with reviewers: the failure it prevents (planning on a false premise) is caught by *citation discipline*, which is cheaper than a reviewer deciding whether research was thorough — and the reviewer is the expensive, unreliable instrument for that question.
4. **It merges, not adds.** `### Axis Research` (Phase 1.5) and `### Pattern Research` (writing-plans Step B) become one block with one format. `research-path` stops being a decorative back-reference and becomes the pointer the check resolves.

---

## 5. research-to-validate — the loop planning creates

Planning changes which research was needed: a plan makes specific claims ("this file is the only writer", "this helper is already fail-closed", "no retry exists") that the pre-plan research did not have to test. So verification asks a **second question** of the *same single round*:

> **Q-RTV:** For each load-bearing factual claim in the plan — a claim whose falsity changes the design — is there a citation in the research block, and is that citation *about that claim*? List every load-bearing claim that is uncited, and every citation that does not bear on the claim it is attached to.

This is **not** a stage and **not** an extra dispatch: it is question 2 in the PLAN-VERIFY verifier prompt. It closes the loop the owner described (`RESEARCH → PLAN → RESEARCH-TO-VALIDATE`) at the cost of a prompt paragraph, because a new stage here would re-create exactly what this proposal deletes — a second round over an artifact that has not changed between the two rounds.

**Failure it prevents, named:** the fleet's two "fixed" claims that had never landed were *exactly* this — a claim in an artifact (a PR body, a plan) that no citation covered. The difference: there the fresh reviewer at the exact head was the only thing that caught it. Here the same question is asked systematically, one stage earlier.

---

## 6. The review scope contract (replaces short cycle caps)

**Declared in the PLAN artifact, before any review is dispatched** — because the reviewer's remit is the thing being declared, and a remit declared after the review is a description, not a contract.

**One normative template, seven classes.** The block is defined once in `review-discipline` §The Review Scope Contract and that definition wins wherever a consumer restates it (this document, the plan comment, `code-review`). Classes: `code`, `gate-enforcement`, `protocol`, `docs-product`, `docs-marketing`, `ops-infra`, `research-decision`; a gate/enforcement change adds a `Threat classes` sub-block, which is where the pre-#2861 `### Adversarial Threat Surface` now lives. `code-review` reads the `### Review Scope Contract` heading and its `**Class:**` line, so the PLAN stage must emit the contract under that heading — a numbered field with the heading inlined is invisible to the consumer.

```markdown
### Review Scope Contract
**Class:** <one of the seven>
**Risk surface** — what this change can break, each with the check that would catch it:
- R1 <failure this change can cause> → caught by <test / assertion / gate / measurement>
**Threat classes** (gate-enforcement only) — `T1 <bypass class>`, or `(not adversarial)`.
**Out of scope — must NOT be raised** (note, file, do not chase):
- pre-existing defects outside the diff · style/prose with no behaviour change
- architectures the plan did not propose · incidental test/fixture shape
**Acceptance:** every `R<n>` has its named evidence and no open item on the declared surface.
```

**"What matters" is defined, not felt.** A finding is **in scope** iff one of:

- **(a) caused** — the diff introduces it;
- **(b) newly reachable** — the diff makes an existing failure reachable, or value-bearing, when it was not;
- **(c) purpose-defeating** — it defeats the change's own stated objective or its declared risk surface.

Otherwise it is `OUT-OF-SCOPE:`, recorded in one line with a suggested issue title, and **it does not extend the loop**. The reviewer is not asked to be less careful; it is asked to be careful about a named surface and to *label* what falls outside it — which is what makes the label countable (§13) and stops the "one more side fact" treadmill.

**Why the cap goes and what replaces it:** a count is a proxy for "the reviewer is still finding real things", and it is a bad proxy in both directions — it truncates a review that is finding real defects (the owner's "far too little") and it flatters one that is finding nothing but admin. The acceptance criterion becomes **coverage of the declared surface**, which is what the adversarial domain already does (`issue-scoping` §Adversarial Threat Surface: "every declared class covered by a test + green CI, residuals filed from cycle 1, not chased"). This proposal generalizes that rule to **every** class, and the generalization is the whole of decision #2.

A runaway guard remains — `AGENTS.md` §Hard Cap's 10 — and it is explicitly *not* an acceptance criterion: reaching it is an escalation exit, never a clean one. For the adversarial domain the retained ceiling is 2, unchanged until step 2; the pipeline's "one round" therefore reads *1 for non-adversarial classes, ≤2 for a change that declares `Threat classes`*.

**One declared surface, not two.** The pre-#2861 `### Adversarial Threat Surface` becomes a **`Threat classes` sub-block inside the contract**, with `THREAT SURFACE COVERED` as its clean exit. Two surfaces with two acceptance rules in one artifact was the state after the first draft, and it made a compliant adversarial review non-conforming to the router.

**Acceptance is recorded, or it cannot be read.** The replacement for a machine-parsed cap must itself be readable: PROVE pastes the contract with each `R<n>` marked `covered` and the command + output that covers it, plus an `OUT-OF-SCOPE: <n>` count. Without that, this design would have swapped a table-parsed number for an unverifiable assertion — which a reviewer of the first draft correctly named as the weakest part of it.

**What is deliberately unchanged:** fresh-context review at the **exact head**, the head-bound attestation (`scripts/record-review.sh`), the merge rail's refusal of a stale record, and "never edit a PR body after recording" — because those caught real failures on 2026-10-26 and nothing here touches them.

---

## 7. The discipline router (artifact → canon → questions)

A single universal checklist is *why* reviews raise side facts: a reviewer asked "is this correct?" about a marketing doc has no canon to be correct *to*, so it invents one. The router names, per class, the canon the artifact answers to and the questions that canon asks.

| Class | The canon it answers to | The reviewer asks | It must **not** ask |
|---|---|---|---|
| **code** | the merge rail + `AGENTS.md` hard rules + `config/surface-manifest.yml` + the plan's `Integration Surface Map` | Is the fail-closed polarity right (a gate that cannot run must not pass)? Does a test fail *without* the diff (mutation proof)? Surface change approved? Attestation at this head? | marketing positioning; doc prose; whether the architecture could be nicer |
| **docs-product** | `docs/00_index.md` placement (Diátaxis), the doc's own stated contract, `docs/ONTOLOGY.md` terms | Does every behaviour claim trace to code/tests in this tree? Do links resolve, is it in the index? | absolute factual correctness of the *world*; code style |
| **docs-marketing** | the marketing canon for that surface — category architecture, positioning doc, SEO/keyword artifacts, and `skills/seo-content-generation` claim discipline | Is the claim aligned with the category architecture and the positioning line? Does it follow the SEO target? Is a negative universal claimed? | **code correctness**; **absolute factual correctness** (marketing argues a position; its standard is alignment with the canon, not a spec) |
| **ops-infra** | the runbook it amends + `docs/ops/fleet-liveness.md` (declared-population rules) + the reap/ancestry rules | What happens when the tool cannot answer — does it fail closed or declare the unread population? Is it reversible? Could it act on a human's terminal or a peer lane? | product UX; prose taste |
| **research-decision** | the decision's own home (issue, plan doc, Tortoise point) | Is the evidence **measured and dated**, is the contradiction test run, is the `OVERRIDES:` line present when it departs from the default? | implementation detail; style |

**Placement — new, small, and wired into the two places review actually happens:** `skills/review-discipline/SKILL.md`. Not inside `code-review` (1,889 lines): the **PLAN** stage needs the class and the contract *before* code exists, and loading the whole review skill to learn "which canon does a marketing doc answer to" is the bloat this proposal removes. This PR wires the consumers rather than describing them:

- **`code-review` Step 3.6 → new "0a"**: read the PR's `Class:` line, route the question set through the router, state that the class never changes the reviewer *count* (that stays `proportional-gates`'), and record `class-uncertain` when no contract exists;
- **`commit-workflow`**: the class-routing line in its AI review gate, so a non-code artifact is no longer sent through the code panel by default;
- **PLAN** (declare the class + contract) and **PLAN-VERIFY** (ask the class's questions — §3 of the skill appends the class row's questions and must-NOT-ask list to Q1–Q3).

Seven classes: `code`, `gate-enforcement`, `protocol`, `docs-product`, `docs-marketing`, `ops-infra`, `research-decision`. The sixth and seventh exist because the first draft had no home for gate/enforcement code (whose canon is `AGENTS.md` §Hard Cap plus the declared threat surface) or for `AGENTS.md`/`templates/**` (the repo's own protocol, which answers to its drift pins, not to a doc index).

**Fail-closed on an unknown artefact:** a diff that is not clearly one class takes `code` (strictest) and **records `class-uncertain: <why>` in the contract**; the reviewer may re-declare the class in the same round if the artifact clearly belongs elsewhere. An unstated class is never "no review questions"; a guessed class is never silent.

**A path is not a class.** One file can carry two canons at once — `skills/task-workflow-standard/SKILL.md` is an executable instruction (does its machine-pin claim hold?) *and* product prose (do its behavioural claims trace to CI?). The contract is therefore split by **claim**, not by file.

---

## 8. Two open questions, answered with evidence

### 8.1 What is O/I/T validation, and does it earn a stage?

**What it is.** **O**bjective (one sentence: the outcome), **I**ndicators (**≥2**, deliberately plural — `skills/issue-creation/SKILL.md:51-77` states the reason: "single-indicator invites Goodhart's Law gaming"), **T**argets (the numeric bar per indicator). It is a section of the **issue body**, authored at creation by `issue-creation` §1.

**Where it lives.** A body section — and nowhere else machine-readable. `issue-workflow` line 107 "verifies" it by *`warn`*; the four sub-steps around it (align inheritance, O/I/T, label lifecycle, dispatch) are `gate: auto`. No script, CI job or extension parses it: `check-pipeline-compliance.sh`'s five checks (§1) never look at the body.

**What it prevents.** An issue with no falsifiable completion criterion — the failure being *"the lane declares done because a diff exists"*, and its cousin, "we cannot tell whether this worked". It is also the **upstream of the scope contract**: Indicators become `R<n>` evidence and Targets become acceptance (§6). That is its real value, and it is a real one.

**Does it earn a stage? No — it earns a body lint.** Three reasons, in order of strength:

1. **A stage is a transition; O/I/T is a property.** Nothing is *decided* or *produced* by reading a body for three headings. A stage that changes no state is ceremony by construction — and the router's job is to *remove* work (session `issue-workflow` §Gate 0 says exactly this about a different gate).
2. **It is mechanically decidable.** The `Objective` / `Indicators` / `Targets` **headings** present, the objective's body non-empty, ≥2 indicator items, ≥1 target item — the shape §1 emits (not `**Bold:**` fields, which is what the first draft of this reason asserted and what the shipped lint rejects). A regex does this perfectly; an agent reading it does it worse and variably. Given a choice between a stage and a lint for the same property, the lint wins on cost and on reliability — the opposite choice is what produced "warn", which is the *worst* of the three: it costs a read and enforces nothing.
3. **A lane cannot remediate it cheaply, and a stage forces it to try.** If the field is missing the lane must either stop and rewrite someone else's issue (cost, and outside its mandate) or warn (noise). A lint at creation moves the failure to the moment it is cheap — before the issue exists — and a lint at merge (`pipeline-compliance`) catches the fielded-but-forgotten case.

**Recommendation:** delete `oit_validation` from `issue-workflow`'s steps, and implement it as a **body lint** in `issue-creation` — **done in this PR**: three assertions on the shape §1 actually emits — the `Objective` heading present with a non-empty body, ≥2 `Indicators` list items, ≥1 `Targets` item with one per indicator — stated where the fields are authored. (`**Objective:**`-style bold fields are **not** what §1 produces, and the first draft of this lint asserted them; the reviewer caught that a compliant body would have failed its own check.) The machine half — one check in `check-pipeline-compliance.sh` (step 2, same edit as the research marker: the scoping comment must quote the objective line it is implementing) — does **not** ship here, and §9 says so rather than implying it.

### 8.2 Is `Label Lifecycle` still needed?

**No. Recommend deletion.** The evidence is not "the new system is better"; it is that the labels have **no reader** and the mechanism they claim to provide is provided elsewhere.

1. **No reader anywhere — and 16 writers.** A search across `agent-infra` and `tortoise` (`scripts/`, `tools/`, `extensions/`, `config/`, `skills/`) finds **no read** of `implementing` / `scoping` / `planning` / `planned`: no label filter, no gate, no report. The count is stated as a command rather than an adjective, because this paragraph got the number wrong three times in review — twice by counting with a regex that misses the *quoted* and *variable* forms (`--remove-label "scoping"`, `--remove-label "$OWN_ING_LABEL"`):

```
git grep -n -e add-label -e remove-label origin/main -- skills templates \
  | grep -E 'implementing|implemented|scoping|scoped|planning|planned' | grep -v 'complexity:'
```

→ **16 write commands across 4 skills** — `issue-workflow` ×5, `executing-plans` ×4, `issue-scoping` ×4, `writing-plans/05` ×3. (The narrower `-E "(add|remove)-label (…)"` form reads 13, because it cannot see the three quoted or variable writes. Two counts, one measurement: name the command, not the number.) (`implemented`, set on completion, is likewise unread; the durable signal is that the issue is closed.) **This proposal therefore deletes every writer, not just the section** — leaving the writers would leave the machinery the section justified.
2. **The collision function moved and the labels cannot reach it.** `scripts/orchestrator-harness/claims.sh` pushes `refs/claims/<pr>-<sha12>` as an atomic compare-and-swap — cross-box, content-addressed, lease-carrying. `tools/fleet/claim_lanes.py` is its reader, and `tools/collision_preflight.py`'s claim gate has read the **holder** (fleet-board attribution + that lane's own `session.pid_alive`) since #8175, never comment prose. Issue-level ownership is the board's attribution; a GitHub label is neither the CAS nor the attribution.
3. **It is not merely redundant, it is unsound.** Step 1 of the snippet removes `implementing` **unconditionally** ("Self-cleanup stale label from crashed prior run") before checking who holds the issue: `gh issue edit $ISSUE --remove-label implementing`. Run by lane B on an issue lane A is actively working, that strips A's only marker — so the one mechanism the block provides is also the one it can silently delete. Since nothing reads the label, the removal costs nothing today; that is precisely the point: it was never load-bearing.
4. **What the registry cannot do, that the labels could:** a human glancing at the issue page sees "someone is on this". That is a **UI affordance**, not coordination — and it has a supported verb now: `tools/who-is-on.sh <N>` ("who holds #N", local-only branches and worktrees included) and the fleet board. Accepted risk: a human loses the one-glance signal *on the issue itself*; the verb answers better (it sees unpushed branches, which a label never did) but requires knowing to ask.

**So: delete the section and the `label_lifecycle` step.** Do not replace it with a different label.

---

## 9. Deletion list — every removed gate, the failure it prevented, where that failure is caught now

| Removed | Failure it prevented | Caught instead / accepted risk |
|---|---|---|
| **SCOPE and PLAN as separate stages** | planning a solution to an unpinned problem | The merged artifact's **fixed field order** (problem definition before plan) plus PLAN-VERIFY Q1. *Accepted risk:* no mechanical check orders the sections before review; the verifier's coverage is the guard. |
| **The `writing-plans` artifact split** (a `docs/plans/*.md` doc *and* a scoping comment) | the plan living in two places that can disagree — and, after this change, the plan doc disappearing entirely | **Both are kept, and their roles are now distinguished**: PLAN saves `docs/plans/<date>-issue-<N>-<slug>.md` with the `<!-- research-path: … -->` header (the **reviewed** artifact), then posts the marker-first comment that mirrors it (the artifact CI reads). ⚠️ **CI check (d) does not require the doc**: it passes on a plan-doc change **or** a case-insensitive `wiring` mention anywhere in the issue's comments (`check-pipeline-compliance.sh:1368`), which the `### Wiring` table always provides — so only (b)'s marker position and (c)'s head-bound record are unconditional. *Accepted risk:* two artifacts can drift — mitigated by making the comment a mirror and the doc the reviewed one, and by stating that the doc is **not** machine-enforced. |
| **`problem-verify` (§2.5) as its own gate** | a shallow problem-diverge reaching the plan | Merged into the single PLAN-VERIFY round; the **research gate's `FALSIFIER`** field is the cheap, pre-review detector (a plan with no falsifier is a plan with no defined failure). |
| **`solution-verify` (§5.5) as its own gate** | the same, on the solution side | Same round; `R<n>` risk surface items are the solution-domain questions in falsifiable form. |
| **`SCOPE-VERIFY` (task-workflow-standard)** | *(nothing — it re-dispatched the same verifier counts over the same artifact as §2.5/§5.5)* | Nothing to catch: this is a duplicate round (§1). Removing it removes a dispatch, not a check. |
| **`plan-review` as a stage in the task pipeline** | a plan nobody reviewed | PLAN-VERIFY covers the plan questions; `plan-review` the **skill** is not deleted (project-workflow still consumes it). |
| **Per-round "fix → re-dispatch ALL verifiers" loops** | a fix that does not fix | One round per gate: **residuals on the declared surface block**, `OUT-OF-SCOPE:` notes are filed, and a fix is re-checked **against the whole declared surface by a FRESH verifier dispatch (a new `task`), inside the same round** — rounds bound the loop, contexts bound confirmation bias (`AGENTS.md` §Review Loop Protocol). That re-check is the catcher for a *design* regression — PROVE's tests and the exact-head code review review **code**, so they cannot see a plan/design regression and are not claimed as its substitute. |
| **The cycle count as an acceptance criterion** | a loop that never terminates | Coverage of the declared surface (§6); the 10-cycle fallback remains as a **runaway guard**, never as acceptance. |
| *(retained — NOT removed in this PR)* **`adversarial-bound: cap=2`** | an unbounded loop on gate code | **Retained verbatim** (asserted: exactly one occurrence, value 2, in `task-workflow-standard`). Retirement is step 2 (§11) because it is machine-pinned on 8 surfaces and in the harness fence — moving it inside a design PR would be the half-state this proposal forbids. |
| **`Label Lifecycle` — the section AND every write site** (16 write commands: `issue-workflow` ×5, `executing-plans` ×4, `issue-scoping` ×4 including the Entry/Exit pair, `writing-plans/05` ×3 including the `planned` write) | two agents on one issue | `claims.sh` CAS + `claim_lanes.py` + the preflight holder gate (§8.2). *Accepted risk:* loses the one-glance label on the page; `who-is-on.sh` answers better but must be asked. |
| **`oit_validation` as a step** | an issue with no falsifiable done-state | **Creation-time body lint in `issue-creation` §1 — landed in this PR** (three decidable assertions, §8.1). *Still missing:* the machine reader (a `pipeline-compliance` check, step 2 §11), so an issue created by hand, or by a lane that skips `issue-creation`, is unchecked until then. |
| **The dual-granularity research requirement** (`issue-scoping` Phase 1.5 `### Axis Research` + `writing-plans` Step B `### Pattern Research`, with "the scoping artifact is PRIOR_RESEARCH for planning, **never a substitute**") | research restarted at the wrong granularity: the plan's concrete claims were never tested at plan level | Merged into **one** artifact (§4) whose `Falsifier:`/`Gaps:` are the plan-level restatement, and the plan-level test is **PLAN-VERIFY Q2** (claim ↔ citation, resolved). *Accepted risk:* one block means one pass — a claim introduced by the plan that no query covers is caught only by Q2, not by a second research round. |
| **The superseded mandates left standing in `issue-scoping` and `writing-plans`** (§2.5 `problem-verify`, §5.5 `solution-verify`, `### Gate Loop — MANDATORY`, `workflow/05`'s `Plan Review Gate … MANDATORY`, `workflow/02`'s `### Axis Research` + `### Pattern Research` split) | **the inverse of a missing gate: the removed stage keeps its mandate**, so a lane that follows the file it was pointed at pays three pre-code rounds while the new skill says one — the redesign would be unenforceable by instruction | Reciprocal notes **in the file where each mandate lives** (`issue-scoping` top banner + Gate Loop + **Phase 8 and its Axis-Research staging step**, `workflow/01`'s prerequisite stop, `workflow/02` Step A + Step B's heading, `workflow/04`'s `### Pattern Research` slot, `workflow/03`'s placement rule, `workflow/05` heading + its `status=` branch list, **`plan-review` §When to Use + §Phase 4 (the marker's owner)**, `reference/research-protocol`'s authorship boundary, `proportional-gates`'s dependency table, `writing-plans/SKILL.md`'s skip-cost table, and **the adversarial-bound trigger's declaration shape in `code-review` / `fixer-loop` / `plan-review` / `proportional-gates`**): each states that `task-workflow-standard` consumes the section for data only, or that PLAN-VERIFY already satisfies its gate. They stay mandatory for `epic-workflow`/`project-workflow`, which is why the note is scoped rather than deleted. |
| **`## Verifier Gate Protocol`** (the "gate stays locked until ALL verifiers return clean, then fix → re-dispatch ALL" contract) | a fix that does not fix, or a P0 found only on an independent second pass | One round per gate with a **whole-surface re-check after a fix, by a fresh verifier dispatch** (§3) — the re-check is against the contract, so it is not a new pass over an unchanged artifact, and it is not a same-context re-review either. *Accepted risk:* a second *independent* pass can find what one pass missed; PROVE (tests/mutation) and the exact-head code review are the only second looks, and they look at code, not at the plan. |
| **`## Nudge Protocol`** (the pre-gate announcement text shown when the skill is read) | a lane surprised by a gate it did not expect | The gate is stated **in the stage header it belongs to** ("gate: …"), where it is read at the moment it applies. A separate narration block is the drift risk it was meant to prevent. *Accepted risk:* none observed — it was narration, not a check. |
| **`## Relationship to project-workflow`** (the full Level / escalation / fallback matrix) | routing standard work into the wrong pipeline | The matrix has **one owner**: `issue-workflow`'s dispatch table (§Routing), which already carries the Level/complexity rows and the fallback. This skill keeps only the escalation rule (decompose → `project-workflow`). Duplication of a routing table in two files is the drift class the deletion removes. |
| **`issue-scoping`'s `### Label Management — Exit`** (`scoping` → `scoped`) | the same collision bookkeeping as the entry block | Deleted with its siblings — `scoped` has no reader either, and leaving it would have kept the machinery the rest of the deletion removes. |
| **`executing-plans`' `# Label Management — Execution Start` status guard** ("warn if `dropped`/`failed`, do not auto-resume without human confirmation") | auto-resuming an issue the fleet had already marked dropped or failed | **Accepted risk, and the one real loss in the label deletion:** the guard was real and `who-is-on.sh` does not replace it. Its durable signals still exist — the issue's own state and the plan doc's `doc_status` — so a lane can still check them, but nothing instructs it to. A follow-up, not a silent drop. |

Nothing in this table deletes an **artifact check** — checks a. through e. of `check-pipeline-compliance.sh` are untouched, and this proposal adds to that list (research marker, O/I-T) rather than removing.

---

## 10. Enforcement posture — the design that survives a host with nothing installed

The fleet finding is the constraint: on the cells, skills did not exist (98/98 dangling symlinks; `~/.pi/agent/skills` empty) and 0 of 46 extensions were present. An enforcement design that lives in a skill therefore enforced **nothing** there, silently.

**The inversion, stated once:** *a load-bearing rule is a check on a repo artifact; a skill is the how-to.* Consequences:

- **Enforced, host-independent:** what CI reads from the repo being merged — `check-pipeline-compliance.sh` (issue link, scoping marker, **research marker**, **plan evidence — a plan doc or a `wiring` mention**, attestation at head, test evidence, **O/I-T**) and the merge rail (`admin-merge.sh` + `ci_exemption.py`). A cell lane with no skills is blocked exactly as a Mac lane is.
- **Host-local, a shortener not a guarantee:** `skill-enforcer`'s manifest rules and `review-enforcer`'s reviewer pre-flight. Useful (they refuse *earlier*, before the work is done) and explicitly not the guarantee — a restored read from a previous session clears a hard gate for 24 h, so a read gate cannot be compliance.
- **Fail loud when the artifact is missing:** `check-pipeline-compliance.sh` already prints the missing artifact **and** the skill that produces it ("Every failure names the missing artifact AND the skill that produces it", its header). The research check inherits that wording, and names the install path when the comment is absent *because the host never installed skills* — the case that used to be silent.

**One cheap enforcement gain available now, recommended for step 2:** add `issue-workflow` and `task-workflow-standard` manifest rules to `enforcement/dangerous-ops.txt` (patterns on `gh issue view` / plan-doc writes) so a lane is told about the workflow *before* it does the work. This is not a one-line edit: `scripts/ci/enforce-protocol-table.sh` (PASS 2) requires every manifest skill to appear in `AGENTS.md`'s protocol table, so the manifest rule and the table row land together — and `enforcement/**` + `AGENTS.md` are both in the ALWAYS-FULL review class, so it is a step-2 edit with its own `clean`-tier review, not something smuggled into this PR.

---

## 11. Sequenced landing (what this PR is, and what follows)

| Step | Content | Why it is not in this PR |
|---|---|---|
| **1 — this PR** | proposal; `skills/issue-workflow` (router only: decided-ruling path, O/I/T → lint, Label Lifecycle deleted); `skills/task-workflow-standard` rewritten (4 stages, research gate contract, research-to-validate, scope contract); `skills/review-discipline` (the router) | The owner reviews the design before it governs anything. |
| **2 — enforcement + the cap** | (a) `scripts/check-pipeline-compliance.sh`: research marker + O/I-T checks, with tests in `scripts/check-pipeline-compliance.test.sh`; (b) retire `adversarial-bound: cap=2` → surface-coverage acceptance; (c) manifest rules for the two workflow skills **plus their `AGENTS.md` protocol-table rows** (`scripts/ci/enforce-protocol-table.sh` PASS 2 requires both) | (a) is a merge-rail input (`ALWAYS-FULL` class ⇒ `clean` tier, real review). (b) is **machine-pinned**: the anchor lives on **8 surfaces** — `AGENTS.md`, `templates/AGENTS.base.md`, `skills/{proportional-gates,code-review,plan-review,issue-scoping,task-workflow-standard}/SKILL.md`, `skills/code-review/references/fixer-loop.md` — pinned by `extensions/loop-enforcer/tier-config-parity.test.ts` (`ADVERSARIAL_CAP`, `ADVERSARIAL_SURFACES`, `adversarialBoundViolations`, plus negative controls at `:805-830`), and the cap is *also* in the harness's own cycle fence (`ADVERSARIAL_BOUND` → `EXIT_REASON="adversarial-capped"`, parsed by `adversarialReachabilityViolations`), with a third pin in `tests/materialize-agents/run.sh:337`. Moving it without all three is drift; doing all three inside a design PR, before the design is approved, is exactly the half-state this proposal forbids. **Until step 2 lands the cap stays in force and no domain may claim a shorter one.** |
| **3 — measure** | the three numbers in §13 (rounds; contract coverage; P0/P1 close rate) on the next 5 standard lanes and the next 3 P0/P1 issues | Needs lanes run under the new text. |

---

## 12. What this PR changes in behaviour, and what it does not

**Changes:** the standard/complex task pipeline's stage list and gate count; the research requirement's *form* (checked artifact rather than prose); the reviewer's remit (declared surface, labelled out-of-scope); which canon a non-code artifact is reviewed against; the routing of a **decided ruling** (`issue-workflow` §Decided-ruling path, implemented in `task-workflow-standard` §Decided-ruling path); and the router's rung list.

**Does not change:** any `AGENTS.md` hard rule (surface approval, worktree isolation, attestation at the exact head, never edit a PR body after recording a review); the merge rail; `record-review.sh` and its tier caps; `proportional-gates` §Review Cycles' table (parsed by `tier-config-parity.test.ts`); the `adversarial-bound: cap=2` anchor (retained verbatim in the rewritten skill, single occurrence); `epic-workflow` / `project-workflow` (they consume `plan-review` and `issue-scoping` unchanged); and no product code — no `TOOL_REGISTRY`, no SDK surface.

---

## 13. How this is falsified (the numbers to read, and what would prove it wrong)

Aimed at the standing goal — deliver every Tortoise P0 and P1 — so the claim is about *finishing*, and it is measured, not asserted. **Three numbers, each with the command that reads it.** Baseline is taken on the day step 3 starts (before the first lane runs under the new text) — a number with no baseline cannot be "flat".

| # | Signal | Read from (instrument) | Wrong if |
|---|---|---|---|
| 1 | Blocking pre-code review rounds | the `**Rounds:**` line in the plan comment (written at PLAN-VERIFY close, field 8; **`1 (verifiers: 1, class: <class>)`** on the lean path, so the path with the least scrutiny still reports). **`<n>` = verifier rounds spent at this gate, initial round included** — a fix plus its fresh re-check is `2`, and each re-check consumes the `AGENTS.md` §Hard Cap bound like any cycle. Read with `gh issue view <N> --json comments --jq '.comments[].body' \| grep -F '**Rounds:**'`. Self-reported by the lane until step 2 folds it into the CI check — stated, not hidden | **≥3 for a non-adversarial class**, or **>2 for a change declaring `Threat classes`**. A reading of `2` is the design working (one round, one fix, one re-check), not a defect — a threshold of `>1` would falsify every lane that found something real. |
| 2 | Contract coverage at PROVE | the PROVE close-out pasted in the PR body, in the literal shape PROVE requires: one line per risk, `- R<n>: covered — <command> → <output>`, or `- R<n>: open — <what is missing>`, plus `OUT-OF-SCOPE: <n>`. Read with `gh pr view <PR> --json body --jq .body \| grep -E '^- R[0-9]+: (covered|open)|^OUT-OF-SCOPE:'`. Self-reported until step 2 checks it against the contract in the plan comment | any `R<n>` `open` at merge → the contract is not the acceptance criterion in practice. A rising `OUT-OF-SCOPE` count with no filed issues → the labels are being used as a mute button. |
| 3 | P0/P1 delivery | **three** closed counts on tortoise, summed — `gh issue list --repo daniel-ospina/tortoise --label <L> --state closed --search "closed:>=<baseline-date>" --json number --jq length` for `L` ∈ {`P0-blocker`, `P1-severe`, `P1`}. **Assert all three exist first** (`gh label list --repo daniel-ospina/tortoise`) and report each count separately, not just the sum | flat or worse over 3 weeks against the baseline → the bottleneck was never review; this proposal costs without paying. **A 0 is UNREAD, not flat, unless all three labels were confirmed to exist** — `gh` ANDs repeated `--label` flags, and this repo has no `priority:P0`/`priority:P1` at all (its labels are `P0-blocker` and `P1-severe`; tortoise#9633 records a "0 open P0 / 0 open P1" reading that this exact artifact produced). |

**Two mechanism-attribution checks** (they say whether the *new gates* did the work, not just whether the outcome improved):

- **Research gate (CI half):** count blocked runs of `check-pipeline-compliance.sh` whose named failure is the research locator. **0 across the first 5 lanes** → the CI half is ceremony; demote it to a lint, keeping Q2.
- **Research gate (Q2 half):** count PLAN-VERIFY rounds returning an uncited/unresolvable claim. This is the half that catches a false premise; a positive reading here **cannot** be credited to the CI check, which is why the two are counted apart.

**The one condition that proves the design wrong:** **≥1 of the first 5 standard lanes reaches BUILD on a problem definition its own research does not support** — the `FALSIFIER` field in §4's template, the only field whose observation is *scheduled by the plan* and therefore the one a write-time check cannot fake. That restores the second diamond gate and retires decision #1's merge for this tier. It is the `FALSIFIER` written in §4's template and in the #2861 plan comment.

---

## Research provenance (anchor)

See §2. Query log: `web_search` `model=sonar` × 4 attempted, 3 returned on first issue + the 4th after one re-issue (HTTP 429); `mcp_load seo-intelligence` failed (server absent) so rung 1 was unavailable and rung 2 was used, stated per the research skill's Step 0.0 preflight requirement. Internal sources are cited by path and line from this checkout at `6b01f4f00`.
