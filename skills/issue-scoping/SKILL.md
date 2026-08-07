---
name: issue-scoping
description: "MANDATORY before implementing any issue. Double diamond: diverges on problem and solution before converging, with verification gates after each diamond. Produces plan with confirmed problem definition, evaluated alternatives, complexity ratings. Skipping causes unplanned code with no review gates."
domain: capability
version: 5.1.0
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> **Orchestration note:** This skill uses body-text orchestration, not YAML steps. The Process Flow + Tier Scaling table define the routing. The sequence enforcer reads the Process Flow and Tier Scaling sections, not frontmatter steps. This avoids the tier-branching problem — Micro, Standard, and Complex follow different gate paths that can't be expressed in a flat steps list.
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Human approval gate:** presents output for user review. Pipeline advances after approval.
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

> **Canonical:** `agent-infra/skills/issue-scoping/SKILL.md` — git-tracked source of truth. Pi reads via `~/.pi/agent/skills`; consumers hard-link into `operations/skills`.
>
> **v5.1.0 — Double Diamond with Integrated Verification Gates.** Each diamond now has a verification gate (2 parallel verifiers + controller tiebreaker) before proceeding. Micro tier gets a single gate after both diamonds. See #7498.

# Issue Scoping

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

Multi-phase planning for **existing** GitHub issues. Uses the **double diamond** design framework with integrated verification:
1. **problem-diverge** — explore alternative problem definitions, root causes, dependencies
2. **problem-converge** — evaluate framings, pick best, confirm with evidence
3. **🛡️ problem-verify** — 2 parallel verifiers check diamond quality (Standard+Complex)
4. **solution-diverge** — generate 2-3 distinct solution approaches with tradeoffs
5. **solution-converge** — pick best approach, draft plan, document rejected alternatives
6. **🛡️ solution-verify** — 2 parallel verifiers check diamond quality (Standard+Complex)

This covers **"what & why"**: requirements, scope, constraints, and validated approach. Detailed implementation design ("how") — bite-sized TDD tasks, design decisions — is handled by `writing-plans` after human approval.

**Prerequisite:** Issues should be created via `issue-creation` first (provides complexity ratings and strategy clarity).

## Design Principle: Quality Over Convenience

**Scoping's job is to find the right approach, not the easy one.**

The Double Diamond generates multiple alternatives — but the converge step can still pick the path of least resistance. This principle hard-codes the rule: **when choosing between approaches, prefer the one that produces the better outcome over the one that's easier to implement.** Quality of result trumps implementation convenience.

**What this means at each convergence point:**

| Diamond Phase | Easy Path (rejected) | Right Path (enforced) |
|---|---|---|
| problem-converge | Accept the issue's framing because researching alternatives costs queries | Challenge the framing; the cost of solving the wrong problem dwarfs the cost of research |
| solution-converge | Pick the approach with fewer files to touch | Pick the approach that handles edge cases, failure modes, and future needs |
| plan drafting | Scope narrowly to keep the implementation plan short | Surface hard dependencies, migrations, and error handling — even if it makes the plan longer |

**Gate:** At each convergence point (Phases 2 and 5), ask: "Which approach produces the better outcome?" The verification gates (2.5 and 5.5) enforce this — verifiers explicitly check for convenience-over-quality shortcuts.

## Design Principle: Fix Root Causes, Not Symptoms

When problem-diverge discovers that the issue describes a symptom rather than the root cause, scoping MUST target the root cause — not the symptom the issue author happened to notice.

**Examples:**
- Issue: "Add retry button to failed uploads" → Root cause: uploads fail silently with no error surfaced → Scope: surface errors + add retry
- Issue: "Increase timeout on X endpoint" → Root cause: N+1 query under load → Scope: fix the query + keep timeout as safety net
- Issue: "Add validation to form Y" → Root cause: API accepts invalid data without rejecting → Scope: add API validation + add client validation

**Gate:** When problem-converge picks a confirmed problem definition, compare it to the original issue. If the original described a symptom and scoping settled on a fix for that symptom without addressing the root cause, the scoping is incomplete. The verification gates (2.5) check for this.

## Design Principle: File Extra Issues, Don't Silently Absorb

Scoping often discovers things that are genuinely separate from the issue at hand — adjacent bugs, unrelated improvements, documentation gaps, tech debt. These are NOT hard dependencies and should NOT be silently absorbed into the scope. They should be filed as separate GitHub issues so they're tracked, prioritized, and owned independently.

**What to file vs what to absorb:**

| Finding | Action |
|---|---|
| Hard dependency (can't ship without it) | Absorb into scope |
| Soft dependency (should ship together, could ship separately) | File issue, link as related, flag in plan |
| Adjacent bug discovered during scouting | File issue, notify user, do NOT absorb |
| Tech debt in touched area (not caused by this issue) | File issue, note in plan, do NOT absorb |
| Documentation gap discovered | File issue, do NOT absorb |
| UX inconsistency noticed in adjacent component | File issue, do NOT absorb |

**Notification:** When filing extra issues, notify the user with a summary:
```
📋 N extra issues filed during scoping of #X:
- #Y: <title> (adjacent bug in <component>)
- #Z: <title> (tech debt in <area>)
```
This prevents silent scope creep — the user knows what was found and can prioritize independently.

## Process Flow

```
Phase 0: Tier classification + Skill-domain detection + Epic/component detection
Phase 1: problem-diverge
Phase 2: problem-converge
Phase 2.5: 🛡️ problem-verify (Standard+Complex: 2 parallel verifiers + controller tiebreaker)
Phase 3: Codebase Explorer + UX Prototype Gate (fed with verified problem)
Phase 4: solution-diverge
Phase 5: solution-converge
Phase 5.5: 🛡️ solution-verify (Standard+Complex: 2 parallel verifiers + controller tiebreaker)
           └─ OR full-diamond-verify (Micro: 1 verifier checks all 4 phases)
Phase 6: Wiring Check
Phase 7: Parallel Review Gates (4 agents + fix loop)
Phase 8: Finalize + post plan
```

### Tier Scaling

| Phase | Micro | Standard | Complex |
|-------|-------|----------|---------|
| problem-diverge sub-agents | 1 | 2 | 2 |
| problem-converge sub-agents | 1 | 2 | 2 |
| **problem-verify** | Skip | ✅ (2 verifiers) | ✅ (2 verifiers) |
| solution-diverge sub-agents | 1 | 1 | 2 |
| solution-converge sub-agents | 1 | 1 | 2 |
| **solution-verify** / **full-diamond-verify** | ✅ (1 verifier, all phases) | ✅ (2 verifiers) | ✅ (2 verifiers) |
| Codebase Explorer | Skip | ✅ | ✅ |
| UX Prototype Gate | Skip | If UX_RATING ≥ medium | If UX_RATING ≥ medium |
| Wiring Check | ✅ | ✅ | ✅ |
| Parallel Review Gates | Skip | ✅ | ✅ |

> **Micro tier:** Runs all 4 diamond phases (1 sub-agent each) + a single full-diamond-verify gate at the end. Prevents solving the wrong problem the wrong way, even for small changes.

> **Skill-domain + shared-code override:** Micro-tier issues touching `skills/`, `operations/pi-config/`, `src/lib/`, `src/hooks/`, `src/services/`, `supabase/migrations/`, or `src/types/` (excluding `_deprecated/`) are upgraded to Standard.

---

## Phase 2.5 — problem-verify: Verify Problem Diamond (Standard + Complex)

**Purpose:** Before a single line of solution code is considered, verify that the problem diamond was done properly. A shallow problem-diverge or evidence-free converge will produce a plan that solves the wrong thing.

### Gate Mechanics

1. **Dispatch 2 parallel verifier sub-agents** via `task` — both receive the same inputs, reach independent conclusions
2. **Controller (main agent) acts as tiebreaker** — not a script, not mechanical voting
3. **Re-dispatch rule:** If either verifier finds P0 or P1 → controller decides fix-or-ignore → re-dispatch both → repeat
4. **Pass-through rule:** If verifiers find only P2/P3/P4 → controller incorporates them → gate passes. No re-launch needed.
5. **Exit:** Both verifiers return no P0s and no P1s

### Verifier Prompt

```
You are verifying the problem diamond of a scoping session. Check whether problem-diverge and problem-converge were done with genuine rigor — not mechanically, not superficially.

CONFIRMED PROBLEM: <from Phase 2 output>
PROBLEM-DIVERGE OUTPUT: <Agent A + Agent B outputs>
PROBLEM-CONVERGE OUTPUT: <Agent A + Agent B outputs>
ORIGINAL ISSUE BODY: <full issue text>

CHECK FOUR DIMENSIONS:

1. DIVERGE THOROUGHNESS: Did problem-diverge genuinely explore alternatives?
   - Are there alternative problem framings that differ meaningfully from the original?
   - Were adversarial queries run seeking DISCONFIRMATION (not just confirmation)?
   - Were assumptions mapped and tagged [validated]/[unverified]?
   - Were hidden dependencies and affected-but-unmentioned stakeholders identified?
   - WERE THERE NO ALTERNATIVES, or were they cosmetic variations? Flag as P1.

2. CONVERGE RIGOR: Was convergence on the problem evidence-based?
   - Is the chosen definition backed by evidence (citations, data, patterns)?
   - Were rejected alternatives documented with rationale?
   - Is there a falsification check? Confidence score?
   - DID CONVERGENCE PICK THE ORIGINAL ISSUE'S FRAMING WITHOUT CHALLENGING IT? Flag as P1.

3. QUALITY OVER CONVENIENCE: Did convergence prioritize correctness over ease?
   - Was a framing rejected because it required more research?
   - Was the original issue's framing accepted because it's simpler?
   - FLAG any sign that the easy definition was chosen over the correct one.

4. GAPS: What's missing from the problem definition?
   - Edge cases, error states, failure modes not accounted for?
   - Stakeholders or downstream systems not mentioned?
   - Dependencies assumed but not verified?

For each issue:
ISSUE:
  severity: P0|P1|P2|P3|P4
  dimension: diverge-thoroughness|converge-rigor|quality-vs-convenience|gaps
  location: [specific diamond phase or output section]
  description: <what's wrong>
  suggestion: <what to fix>

P0 = structural flaw in problem definition (wrong root cause, impossible to solve as stated)
P1 = important gap (shallow divergence, evidence-free convergence, convenience over quality)
P2 = improvement (could be more thorough)
P3 = nitpick (minor)
P4 = suggestion (nice to have)

If no issues: NO ISSUES FOUND
```

### Controller Logic

After both verifiers return:

```
VERIFIER A: [P0: ..., P1: ..., P2: ...]
VERIFIER B: [P0: ..., P1: ..., P2: ...]
```

**Step 1 — Identify all P0 and P1 issues** across both verifiers.

**Step 2 — For each P0/P1, controller decides:**
- **Fix:** The issue is real → apply the fix to the problem definition/converge output
- **Ignore:** The issue is a false positive → note rationale in cycle log. Example: "Verifier B flagged 'no adversarial queries' but Agent B's challenge report explicitly ran 4 disconfirmation queries"

**Step 3 — Re-dispatch if any P0/P1 was fixed:**
- If controller fixed anything → re-dispatch BOTH verifiers (fresh `task` sessions)
- If controller only ignored → still re-dispatch (verifiers must stop flagging it, or escalate)
- If no P0/P1 found at all → gate passes

**Step 4 — Handle P2/P3/P4:**
- Controller incorporates reasonable P2+ findings
- Does NOT trigger re-dispatch
- Gate passes if only P2+ remain

**Stuckness escalation:** If the SAME P0/P1 is flagged by verifiers for 3 consecutive cycles and controller has ignored it each time → escalate to human. The verifiers see something the controller doesn't.

**Cycle log entry:**
```
### problem-verify — Cycle N
- Verifier A: P0=0, P1=2, P2=1
- Verifier B: P0=0, P1=1, P2=2
- Controller action: Fixed P1-X (missing falsification check), Ignored P1-Y (verifier missed Agent B's adversarial queries — rationale documented)
- Re-dispatching...
```

---

## Phase 5.5 — solution-verify: Verify Solution Diamond (Standard + Complex)

**Purpose:** Before the plan goes to wiring check and review, verify that the solution diamond produced genuinely distinct approaches and converged on the best outcome — not the easiest.

### Gate Mechanics

Same as problem-verify: 2 parallel verifiers → controller tiebreaker → re-dispatch for P0/P1 → pass for P2+ only.

### Verifier Prompt

```
You are verifying the solution diamond of a scoping session. Check whether solution-diverge and solution-converge produced genuinely distinct approaches and converged on quality over convenience.

CONFIRMED PROBLEM: <from Phase 2>
SOLUTION-DIVERGE OUTPUT: <Agent A + Agent B outputs>
SOLUTION-CONVERGE OUTPUT: <Agent A (+ Agent B) plan drafts>
CODEBASE EXPLORER: <from Phase 3, if available>

CHECK FOUR DIMENSIONS:

1. DIVERGE GENUINENESS: Are the approaches truly distinct?
   - Do they differ in architecture or technique (not just file names or variable names)?
   - Does each have named tradeoffs, risks, and "best fit if" conditions?
   - Are there 2+ approaches? If only 1: is it because genuinely no alternatives exist, or because diverge was shallow?
   - ARE THEY COSMETIC VARIATIONS OF THE SAME IDEA? Flag as P1.

2. CONVERGE QUALITY OVER CONVENIENCE: Was the best approach chosen?
   - Does the rationale evaluate outcome quality, edge case handling, failure mode coverage?
   - Or does it evaluate diff size, number of files, implementation speed?
   - Were rejected alternatives documented with "when this WOULD have been better"?
   - DID CONVERGENCE PICK THE APPROACH WITH FEWER FILES TO TOUCH? Flag as P1.
   - IS THERE A BETTER APPROACH THAT WAS REJECTED FOR CONVENIENCE? Flag as P0.

3. PLAN COMPLETENESS: Does the plan surface everything?
   - All states: loading, empty, error, edge cases?
   - For UI: mobile considered?
   - Error handling and failure modes addressed?
   - Runtime prerequisites documented?
   - Concrete, verifiable Acceptance Criteria?

4. WIRING PRE-CHECK: Are integration surfaces accounted for?
   - DB, API, auth, external services, UI components, cross-cutting concerns?
   - Anything clearly missing that Wiring Check (Phase 6) will need to catch?
   - FLAG as P0 if a critical dependency is entirely absent from the plan.

For each issue:
ISSUE:
  severity: P0|P1|P2|P3|P4
  dimension: diverge-genuineness|converge-quality|completeness|wiring
  location: [specific diamond phase or plan section]
  description: <what's wrong>
  suggestion: <what to fix>

P0 = structural flaw (missing critical dependency, wrong approach chosen, better approach rejected for convenience)
P1 = important gap (cosmetic variations, convenience over quality, missing states)
P2 = improvement (could be more thorough)
P3 = nitpick (minor)
P4 = suggestion (nice to have)

If no issues: NO ISSUES FOUND
```

### Controller Logic

Same as problem-verify: identify P0/P1 → fix or ignore → re-dispatch if fixed → pass if only P2+.

---

## Phase 5.5b — full-diamond-verify: Verify All 4 Phases (Micro only)

**Purpose:** Micro tier runs all 4 diamond phases with 1 sub-agent each. A single verifier checks all phases at the end — catching the same failure modes as the Standard/Complex gates but with proportional cost.

### Gate Mechanics

1. **Dispatch 1 verifier sub-agent** via `task`
2. **Controller reviews findings:** P0/P1 → fix or ignore → re-dispatch → repeat. P2+ only → incorporate and pass.
3. **Exit:** Verifier returns no P0s and no P1s.

### Verifier Prompt

Same dimensions as problem-verify + solution-verify combined, but dispatched as a single agent:

```
You are verifying the full double diamond of a micro-tier scoping session. Check all 4 phases for genuine divergence, evidence-based convergence, and quality over convenience.

CONFIRMED PROBLEM: <from Phase 2>
PROBLEM-DIVERGE OUTPUT: <Agent output>
PROBLEM-CONVERGE OUTPUT: <Agent output>
SOLUTION-DIVERGE OUTPUT: <Agent output>
SOLUTION-CONVERGE OUTPUT: <Agent output>
ORIGINAL ISSUE BODY: <full issue text>

CHECK ACROSS ALL PHASES:

1. PROBLEM DIVERGE: Alternative framings? Adversarial queries? Assumptions mapped?
2. PROBLEM CONVERGE: Evidence-based? Falsification check? Confidence score?
3. SOLUTION DIVERGE: Distinct approaches? Tradeoffs documented?
4. SOLUTION CONVERGE: Quality over convenience? Rejected alternatives documented?
5. COMPLETENESS: States covered? Edge cases? Prerequisites? Acceptance Criteria?
6. WIRING: Integration surfaces accounted for?

Severity: P0=structural, P1=important gap, P2=improvement, P3=nitpick, P4=suggestion.
If no issues: NO ISSUES FOUND
```

### Controller Logic

Same as Standard/Complex gates but with single verifier: P0/P1 → fix or ignore → re-dispatch → repeat. P2+ → incorporate and pass.

---

## Human Input Taxonomy (inlined from human-input-framework v2.0.0)

### Research-Before-Ask Protocol (MANDATORY — runs BEFORE any pause)

When a taxonomy match occurs, do NOT pause immediately:

1. **Internal Research** — Search codebase for existing patterns, conventions, or prior decisions
2. **External Research** — Perplexity queries for best practices, how others solve this
3. **Decision:**
   - >80% confidence → Apply decision, note with ponytail comment. DO NOT PAUSE.
   - 50-80% confidence → Apply best-supported option, note rationale. DO NOT PAUSE.
   - <50% confidence → Pause with structured question + research findings.
   - P0 consequence (data loss, security, irreversible, cost >$10/mo, legal/compliance) → Pause regardless.

### Taxonomy Categories — pause for human input when:

1. **Ontology changes** — new tables, columns, relationships, semantic meaning changes
2. **UX changes** — visible user-facing behavior/layout/flow changes not explicitly requested
3. **One-way doors** — destructive operations, data migrations, schema drops, force pushes
4. **Third-party dependencies** — new API integrations, service subscriptions
5. **Cost impact** — changes increasing recurring costs by >$1-3/month
6. **Scope expansion** — implementing beyond what was requested

**Tie-breaking rule:** When uncertain, RESEARCH FIRST. Pause only if research is inconclusive OR P0.

## Phase 0 — Tech-Debt Pre-Flight

Before scoping, surface outstanding test/CI debt:

```bash
npm run check:test-debt
```

If pre-existing failures exist with issue tags matching this issue's component/epic:
- **Warn:** "N pre-existing test failures are linked to issues in this area."
- **Offer:** fix now, defer (acknowledged), or skip
- If user defers: record decision, proceed
- If user skips: proceed silently

**Do not block** — warn-and-suggest only.

## Phase 0 — Read Complexity Ratings

```bash
gh issue view <N> --json body --jq '.body'
```

Extract `TIER`, `UX_RATING`, `ONTOLOGY_RATING`, `ARCH_RATING` from the `**Complexity Rating**` section.

## Phase 0.5 — Epic, Component & Skill-Domain Detection

```bash
ISSUE_BODY=$(gh issue view <N> --json body --jq '.body')
EPIC_DOC_PATH=$(printf '%s\n' "$ISSUE_BODY" | awk '/^\*\*Epic:\*\*[[:space:]]+docs\/epics\// { sub(/^\*\*Epic:\*\*[[:space:]]+/, ""); print; exit }')
RESEARCH_BRIEF_PATH=$(bash scripts/_research_path.sh --issue-body "$ISSUE_BODY" --epic-path "$EPIC_DOC_PATH")
[ -n "$RESEARCH_BRIEF_PATH" ] && [ -f "$RESEARCH_BRIEF_PATH" ] || RESEARCH_BRIEF_PATH=""

# Skill-domain + shared-code detection: upgrade Micro → Standard
case "$TIER" in
  [Mm][Ii][Cc][Rr][Oo]) ;;
  *) TIER_SKIP=1 ;;
esac
if [ "${TIER_SKIP:-0}" != "1" ]; then
  UPGRADE_PATHS=$(printf '%s' "$ISSUE_BODY" | grep -oE '(^|[[:space:]([])(skills/|operations/pi-config/|src/lib/|src/hooks/|src/services/|supabase/migrations/|src/types/)[^[:space:],)]*' | grep -v '_deprecated/' || true)
  if [ -n "$UPGRADE_PATHS" ]; then
    echo "🔧 Shared infrastructure change detected — upgrading from Micro to Standard"
    echo "   Matched paths: $UPGRADE_PATHS"
    TIER="Standard"
    gh issue edit $ISSUE_NUMBER --add-label "complexity:standard" 2>/dev/null || true
    gh issue edit $ISSUE_NUMBER --remove-label "complexity:micro" 2>/dev/null || true
  fi
fi
```

### Issue Number Guard

`issue-scoping` requires a GitHub issue. If no `ISSUE_NUMBER`:
- **Autonomous mode:** auto-create with `gh issue create` and continue.
- **Interactive mode:** ask. If "no issue" → abort.

### Label Management — Entry

```bash
OWN_ING_LABEL="scoping"
# Self-cleanup stale label
if gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -q "^${OWN_ING_LABEL}$"; then
  gh issue edit $ISSUE_NUMBER --remove-label "$OWN_ING_LABEL" || true
fi
# Warn on OTHER in-progress labels
OTHER_LABELS=$(gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -E '^(scoping|planning|implementing)$' | grep -v "^${OWN_ING_LABEL}$" || true)
if [ -n "$OTHER_LABELS" ]; then
  echo "⚠️ Issue #$ISSUE_NUMBER has in-progress label(s): $OTHER_LABELS"
  # Ask user: "Continue anyway?" If no → abort.
fi
# Apply own scoping label
gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -q '^scoping$' \
  || gh issue edit $ISSUE_NUMBER --add-label scoping
```

### Step 1: Read Issue
- Fetch with `gh issue view`
- Understand problem, proposed fix, impact
- Identify affected files and systems

---

## Phase 1 — problem-diverge: Diverge on Problem

**Purpose:** Explore the problem space broadly. The issue body states ONE problem definition — generate alternatives.

### Sub-Agent Dispatch

Dispatch in parallel via `task`. All agents MUST invoke the `research` skill internally.

**Micro:** 1 sub-agent. **Standard:** 2 sub-agents. **Complex:** 2 sub-agents.

#### Agent A (all tiers):

```
You are exploring alternative problem definitions for an issue. The issue body provides ONE framing — your job is to find what it might be missing.

ISSUE BODY: <full issue text>
PROJECT ROOT: <absolute path>
TIER: <micro|standard|complex>

Use the research skill to investigate. Run at least 3 adversarial queries SEEKING ALTERNATIVE ROOT CAUSES. Do NOT research solutions — only problems.

1. ALTERNATIVE DEFINITIONS: What are 2-3 other ways to define this problem?
2. ASSUMPTION MAPPING: List every assumption the issue makes. Tag as [validated] or [unverified].
3. BOUNDARY CHECK: What's OUTSIDE this problem's scope?
4. STAKEHOLDER CHECK: Who else is affected?

Output:
### Alternative Problem Framings
- Framing 1: <definition> (strength/weakness)
- Framing 2: <definition> (strength/weakness)
- Framing 3: <original> (if still valid)

### Assumptions
| Assumption | Status | Evidence/Falsification |

### Boundary & Stakeholders
- Out of scope: ...
- Affected but unmentioned: ...
```

#### Agent B (Standard + Complex only):

```
You are the Devil's Advocate for problem definition. Challenge the issue's problem statement.

ISSUE BODY: <full issue text>
PROJECT ROOT: <absolute path>

Use the research skill with adversarial framing. Seek DISCONFIRMATION.

1. REVERSE THE PROBLEM: "What if the OPPOSITE is true?"
2. PRE-MORTEM: "We implemented the fix and it didn't work. Why?" (3 distinct scenarios)
3. DEPENDENCY HIDDEN COSTS: What does this problem definition assume exists?
4. COUNTER-EVIDENCE: Cases where this type of problem was solved differently.

Output:
### Challenge Report
- Strongest argument AGAINST the issue's problem definition
- Most likely misdiagnosis
- Hidden dependencies
- Pre-mortem scenarios
```

### Step 2 — Collect Outputs

Gather all agent outputs. Proceed directly to Phase 2.

---

## Phase 2 — problem-converge: Converge on Problem

**Purpose:** Evaluate alternative problem framings and converge on the best definition.

### Sub-Agent Dispatch

**Micro:** 1 sub-agent. **Standard:** 2 sub-agents. **Complex:** 2 sub-agents.

#### Agent A (all tiers):

```
You are evaluating problem framings. Pick the BEST definition based on evidence.

ORIGINAL ISSUE: <issue body>
ALTERNATIVE FRAMINGS (Discover): <Agent A output>
CHALLENGE REPORT (Discover): <Agent B output, if available>

Use the research skill to verify claims.

1. EVALUATE each framing: evidence quality, scope fit, actionability, risk of misdiagnosis
2. CONVERGE: Pick ONE. State why. Document rejected alternatives.
3. FALSIFICATION: What evidence would prove this definition wrong?

Output:
### Confirmed Problem Definition
<one clear sentence>

### Why This Framing
- Evidence, rejected alternatives

### Falsification Check
### Confidence (0-100)
```

#### Agent B (Standard + Complex only):

Independently evaluate the same framings. Same output format.

### Merge & Decide

- Both agree → confirmed. Disagree → controller decides with rationale.
- **Micro:** Single agent output is the confirmed definition.

### Human Gate (conditional)

Pause for human approval ONLY if: confidence < 50, agents disagree AND controller cannot resolve, or confirmed definition differs significantly from original. Otherwise: proceed directly.

---

## Phase 3 — Codebase Explorer + UX Prototype Gate

Now with a VERIFIED problem definition (passed problem-verify gate).

### Codebase Explorer (Standard + Complex only)

Dispatch a sub-agent via `task`:

```
You are scouting the codebase for an issue. Do NOT draft a plan.

CONFIRMED PROBLEM: <from Phase 2>
ISSUE BODY: <full issue text>
PROJECT ROOT: <absolute path>

Explore the codebase to find: AFFECTED_FILES, PATTERNS_OBSERVED, PARTIAL_IMPLEMENTATIONS, RECOMMENDED_TESTS, DEPENDENCIES.
Be specific — include file paths and line references.
```

### UX Prototype Gate

Condition: Standard/Complex + UX_RATING ≥ medium.
- Fork mode: modify existing React component, prototype IS the implementation
- Generate mode: new HTML prototype via `ui_prototype` tool
- Run `prototype-review` on output
- Hard stop for human approval

---

## Phase 4 — solution-diverge: Diverge on Solution

**Purpose:** Generate 2-3 DISTINCT solution approaches with tradeoffs.

### Sub-Agent Dispatch

**Micro:** 1 sub-agent. **Standard:** 1 sub-agent. **Complex:** 2 sub-agents.

#### Agent A (all tiers):

```
You are generating alternative solution approaches for a confirmed problem.

CONFIRMED PROBLEM: <from Phase 2>
CODEBASE EXPLORER FINDINGS: <from Phase 3, if available>
PROJECT ROOT: <absolute path>

Generate 2-3 DISTINCT approaches differing in architecture or technique.

For each: name, description, files touched, architecture, risks, tradeoffs, best fit if.

Do NOT pick a winner.
```

#### Agent B (Complex only):

Same agent, independently dispatched with different framing.

### Collect

Gather all outputs. Proceed to Phase 5.

---

## Phase 5 — solution-converge: Converge on Solution + Draft Plan

**Purpose:** Pick the best approach, draft the implementation plan, document rejected alternatives.

### Sub-Agent Dispatch

**Micro:** 1 sub-agent. **Standard:** 1 sub-agent. **Complex:** 2 sub-agents.

#### Agent (all tiers):

```
You are converging on a solution approach and drafting an implementation plan.

CONFIRMED PROBLEM: <from Phase 2>
SOLUTION APPROACHES: <from Phase 4>
CODEBASE EXPLORER: <from Phase 3, if available>
PROJECT ROOT: <absolute path>

⛔ QUALITY OVER CONVENIENCE: Pick the approach that produces the BETTER OUTCOME.
Evaluate on: outcome quality, edge case handling, failure mode coverage, future extensibility.
Do NOT evaluate on: diff size, number of files touched, implementation speed.

1. PICK THE BEST APPROACH. Document why. Document rejected alternatives.
2. DRAFT THE PLAN: problem statement, proposed solution, implementation plan, testing strategy, verification plan, acceptance criteria, runtime prerequisites.

Output the complete plan draft.
```

#### Agent B (Complex only):

Same agent, independently dispatched. Controller merges if both choose same approach; decides with rationale if different.

**Merge tiebreaker:** When equal, prefer better outcome. When one is clearly better and the other easier, pick the better one.

---

## Phase 5.6 — Qwen Coherence Check (Two-Tier Review)

After solution-verify converges clean (both diamond verification gates passed with Flash reviewers), dispatch ONE Qwen3.8-Max reviewer to check **cross-diamond coherence**. Qwen checks that the problem definition and solution approach are consistent, nothing was lost between diamonds, and the scoping output is complete.

**Model:** `qwen3.8-max` (via Token Plan or configured provider).

**Dispatch:**
```
task(model="qwen3.8-max", prompt=<coherence check prompt>)
```

**Prompt:**
```
You are a senior reviewer checking cross-diamond coherence of a scoping session. Both diamonds passed verification individually — your job is to check they HANG TOGETHER.

CONFIRMED PROBLEM: <from Phase 2>
SOLUTION APPROACH: <from Phase 5>
ORIGINAL ISSUE: <issue body>

CHECK:
1. Does the solution actually address the confirmed problem? Or did it drift back to the original issue framing?
2. Were any problem-dimensions discovered in Phase 1 but dropped by Phase 5?
3. Are edge cases from problem-diverge handled in the solution?
4. Is there a SIMPLER approach that would achieve the same outcome? (Devil's advocate)
5. What is the weakest assumption in this scoping?

Output ISSUE blocks or NO ISSUES FOUND.
```

**Qwen findings surfaced as `[QWEN-GATE]`:**

| Qwen Issue | Action |
|---|---|
| `[QWEN-GATE] P0` | Problem-solution mismatch — fix required, re-run Qwen once |
| `[QWEN-GATE] P1` | Important gap — fix required, re-run Qwen once |
| `[QWEN-GATE] P2` | Improvement — note, do NOT re-run |

**Re-dispatch:** Max 2 cycles. On 2nd failure → surface in scoping comment as `[QWEN-GATE]` with "Qwen coherence check could not converge."

**Applies to:** Standard + Complex tiers only. Micro tier skips (single full-diamond-verify is sufficient).

---

## Phase 6 — Wiring Check

After plan draft (Phase 5) and solution-verify (Phase 5.5): verify ALL connections needed to deliver value are covered.

### List Touch Points

- **Data stores:** tables, columns, indexes, migrations
- **APIs:** endpoints, edge functions, RPC calls
- **Auth:** RLS policies, role checks, session handling
- **External services:** third-party APIs, webhooks, email, notifications
- **UI components:** pages, components, modals, forms
- **Cross-cutting:** logging, analytics, error tracking, feature flags

### Verify Coverage

```bash
gh issue list --search "<touch point keywords>" --state open --limit 10 --json number,title,state
```

### Resolve Gaps

**<HARD-GATE>** — Block scoping completion until ALL wiring gaps are resolved.

### Wiring Check Table

| Touch Point | Type | Covered By | Status |
|-------------|------|------------|--------|
| <touch point> | <type> | #N or — | ✅ or ⚠️ |

---

## Phase 7 — Parallel Review Gates

All agents run **in parallel** via `task`. Skip for Micro.

### Agents

**Agent #1 — Codebase & Docs Review:** Codebase patterns, project docs, test infrastructure, bug risk assessment.

**Agent #2 — UX Patterns & Component Reuse:** Existing components, patterns, anti-patterns, layout conventions.

**Agent #3 — Epic Alignment** (conditional, skip if no epic).

**Agent #4 — Devil's Advocate Hypothesis Challenge** (Standard + Complex): Adversarial reasoning, pre-mortem, scoring.

### Gate Loop — MANDATORY

#### Merge-Dedup

After parallel agents return: group by similarity, keep highest severity.

#### Confidence Scoring

Dispatch isolated confidence scorer per issue. Issues < 50 → `[LOW-CONFIDENCE]` P2, logged but NOT in fixer loop.

Each review cycle dispatches FRESH `task` sub-agents.

**Exit conditions (ALL must be true):**
- [ ] Last reviewer response: "NO ISSUES FOUND" (verbatim)
- [ ] If cycle 1 found issues → at least 1 re-review cycle completed
- [ ] Cycle log posted

**Stuckness detection:**
- Fingerprint-stall: ≥80% same issues across cycles → escalate
- Honest-stuck: non-decreasing issue count for 3 cycles → escalate
- Zero-progress: plan unchanged for 2 cycles → escalate
- Convergence: strict subset of prior cycle → escalate with remaining issues
**Safety cap:** 10 cycles.

---

## Phase 8 — Finalize

### Post Plan Comment

```bash
gh issue comment $ISSUE_NUMBER --body "$(cat <<'PLANEOF'
<!-- issue-scoping: v5.1 double diamond + verify -->
## Confirmed Problem
<from Phase 2>

## Verification Gates
<!-- Standard/Complex: -->
### problem-verify: N cycles, clean | N issues remain
### solution-verify: N cycles, clean | N issues remain
<!-- Micro: -->
### full-diamond-verify: N cycles, clean | N issues remain

## Plan
<plan draft>

## Rejected Alternatives
<alternatives and why not chosen>

## Wiring Check
| Touch Point | Type | Covered By | Status |
|-------------|------|------------|--------|

## Review Cycle Log
...

## Complexity
| Domain | Rating |
|--------|--------|
PLANEOF
)"
```

### Label Management — Exit

```bash
gh issue edit $ISSUE_NUMBER --remove-label "scoping"
gh issue edit $ISSUE_NUMBER --add-label "scoped"
```

### Human Gate (conditional)

Pause for human approval if: confidence < 50, P0 issues remain after review, wiring gaps manually resolved.

---

## Key Principles

- **Double diamond is non-negotiable.** Micro tier runs all 4 phases (1 sub-agent each). No issue gets scoped without exploring alternative problems AND solutions.
- **Verification gates after each diamond.** Standard+Complex get 2 parallel verifiers per gate; Micro gets a single full-diamond verifier. P0/P1 → fix → re-verify. P2+ → incorporate and pass.
- **Controller is the tiebreaker, not a script.** When verifiers disagree, the main agent decides. Verifiers flag issues; controller fixes or ignores with rationale.
- **Problem phases use research skill.** Discover and Define invoke `research` for adversarial queries — not just web_search.
- **Quality over convenience in solution selection.** The converge step picks the better outcome, not the easier implementation.
- **Fix root causes, not symptoms.** When problem-diverge discovers a deeper cause, target that — not the symptom the issue described.
- **File extra issues, don't silently absorb.** Adjacent bugs, tech debt, and unrelated improvements discovered during scoping are filed as separate issues — never silently absorbed into scope.
- **Rejected alternatives are documented.** Every approach not chosen has a rationale for when it WOULD have been better.
- **Wiring gaps block completion.** Hard gate — all touch points must be covered.
- **Review is fresh-context.** Every review cycle dispatches new `task` sub-agents.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
