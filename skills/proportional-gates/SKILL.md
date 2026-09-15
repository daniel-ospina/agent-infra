---
disable-model-invocation: true
name: proportional-gates
description: "Reference: replaces rigid/programmatic skill rules with judgment-based gating. Consumed by other skills — not invoked directly. Defines proportionality principle, risk-tiered verification, and the 'reviewer validates judgment' pattern."
subjects.team: organisation-design-team
type: reference
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Proportional Gates

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

## Overview

Rigid rules ("always run 4 reviewers", "always typecheck", "always use a worktree") create bureaucracy without intelligence. They force the same overhead on a 3-line config change as on a 500-line DB migration. This wastes tokens, slows down agents, and produces non-sensical results (typecheck failures attributed to markdown changes).

**Proportional gates** replace mechanical rules with a single principle: **match verification depth to change risk and novelty.** An agent uses judgment to decide what gates to run. A reviewer validates those decisions.

This skill is the canonical reference. Consuming skills cite `proportional-gates` §Review Cycles by name and never copy its cells; the domain tables (workspace isolation, pre-flight verification, dependency verification, research depth) may be inlined — see §Consuming These Tables.

---

## Core Principle

> **The cheapest verification that catches the most likely failure mode. Proportionate to the change. Validated by review.**

Every gate decision follows the same logic:
1. **Classify the change** — what type? what risk? what novelty?
2. **Select proportional verification** — what's the cheapest check that catches the likely failure?
3. **Note the decision** — document what was skipped and why
4. **Reviewer validates** — a fresh sub-agent confirms the gating decisions were appropriate

---

## Change Classification

Before deciding what gates to run, classify the change:

| Dimension | Low | Medium | High |
|-----------|-----|--------|------|
| **Code impact** | Docs, config, CSS, strings only | Single component/hook change | Multi-file, shared types, DB, auth |
| **Surface risk** | No runtime behavior change | UI behavior change, existing pattern | New integration, new data flow, auth change |
| **Novelty** | Following existing pattern exactly | Adapting existing pattern | New pattern, unfamiliar library, first-of-kind |
| **Reversibility** | Trivially revertible | Requires migration rollback | Destructive, data loss possible |

**Overall risk = highest dimension.** A docs-only change with high novelty = Medium (docs are low-risk even if novel).

---

## Proportionality Tables

### Workspace Isolation

| Risk | Isolation |
|------|-----------|
| Low | Plain branch inside a worktree; in a hub, create the worktree first (#626). |
| Medium | Worktree recommended if 3+ files or shared infrastructure. Plain branch OK for single-file. |
| High | Worktree required. Hub dirty → `bash scripts/checkout-hygiene/hub-worktree.sh salvage <branch>` (in-hub `git stash push` is M4-blocked); inside a worktree, stash your own changes. |

**Never** start on main/master regardless of risk.

> ⛔ **Guard note (#626):** "Plain branch" means a branch created from inside an existing
> worktree — in-hub `git checkout -b` is BLOCKED in every repo (the shared main checkout
> must never be flipped; agent-infra's #99 exemption was removed in #615 and the M3
> create-new carve-out in #626). In a hub, create an isolated worktree first
> (using-git-worktrees skill; agent-infra: `bash scripts/checkout-hygiene/hub-worktree.sh <branch>`).

### Pre-flight Verification

| Risk | Typecheck | Build | Integration Tests | pgTAP |
|-------|-----------|-------|-------------------|-------|
| Low | Skip (no TS changes) | Skip | Skip | Skip (migrations = always High) |
| Medium | Run if .ts/.tsx changed | Run if src/ changed | Run if integration surfaces touched | Run if migrations |
| High | Always run | Always run | Always run | Always run |

**Skip rule:** If a check would not catch the change's failure mode, skip it. A markdown change cannot cause a type error. A CSS change cannot break an integration test.

### Review Cycles

| Risk | Reviewers | Max Cycles |
|------|-----------|------------|
| Low | 1 reviewer | — |
| Low-Medium (small plan, existing patterns) | 2 reviewers | 3 |
| Medium-High (large plan, some novelty) | 3 reviewers | 5 |
| High (novel architecture, first-of-kind) | 4 reviewers | 10 |

`—` is the skip sentinel: one reviewer pass, no re-review (the enforcer reads it as 0 loop cycles). A numeric cell counts cycles, where cycle 1 is the first pass. Tier crosswalk: `micro` → Low, `standard` → Low-Medium, `complex` → High. Editing this table requires the matching change in `extensions/loop-enforcer/termination.ts` and `tier-config-parity.test.ts` in the same commit — the parity test parses it.

**Proportional dispatch:** The agent decides how many reviewers to launch based on plan size and novelty. A 20-line plan following existing patterns = 2 reviewers. A 200-line plan with new architecture = 4 reviewers.

**Adversarial domain (bound: 2 cycles) — orthogonal to the rows above.** For gate/enforcement code whose correctness is "an attacker cannot make it fail open" (argv/path/symlink resolution, working-tree discard, merge and verification gates), the budget is bounded by the **declared threat surface**, not by reviewer exhaustion: **cap 2 cycles**, acceptance = every declared threat class covered by a test + green CI, residuals **filed from cycle 1, not chased**. A fresh reviewer returning **`THREAT SURFACE COVERED`** (all declared classes covered, no in-scope bypass reproduced) is this domain's clean exit — a literal `NO ISSUES FOUND` is not required; when the merge rests on threat-list coverage, disclose it in the PR body as `[ADVERSARIAL-BOUND] cycles=<N> threats=<K> covered=<K> residuals=<#N,…|none>`. The declaration is mandatory at scoping (`issue-scoping` §Adversarial Threat Surface). Statement of record: `AGENTS.md` §Hard Cap.
<!-- adversarial-bound: cap=2 -->

### Dependency Verification

| Situation | Action |
|-----------|--------|
| Dep already used elsewhere in codebase | Skip verification — pattern is known |
| Dep is well-known stdlib-adjacent (lodash, date-fns) | Skip — common knowledge |
| Dep is new to codebase AND not in plan's Pattern Research | Verify: 1-2 Perplexity calls |
| Dep is novel, unfamiliar, AND plan has no Pattern Research | Verify: 2-3 Perplexity calls. Pause if unavailable. |

**Perplexity unavailable:** If dep is well-known (used in 2+ other repos, documented extensively), proceed with note. Only pause for genuinely novel deps.

### Research Depth

| Topic novelty | Research calls |
|---------------|---------------|
| Well-known pattern (codebase has 2+ examples) | 0-1 Perplexity calls |
| Pattern exists but choice has trade-offs | 2-3 Perplexity calls (canonical + comparative) |
| Novel pattern, no codebase precedent | 3+ Perplexity calls (canonical + comparative + pitfalls + recency) |
| First-of-kind, unfamiliar domain | 5+ calls (all framings + scale + adversarial) |

---

## The Reviewer-Validates-Judgment Pattern

Instead of rigid rules, skills use this pattern:

```
Agent: "Classified as Low risk — skipping typecheck (no TS changes), 
        using plain branch (single markdown file). 
        Reviewer will validate."
        
Reviewer sub-agent: reads the change, confirms:
  - Classification is correct (are there hidden .ts changes?)
  - Skipped gates would not have caught anything
  - → "Classifications validated: Low risk confirmed. All skips appropriate."
  OR
  - → "Found .ts file in diff — reclassify as Medium. Run typecheck."
```

This is the same generate-review loop applied to gate selection itself. The agent uses judgment; the reviewer catches mistakes; the loop converges.

---

## Findings Must Declare Consequence

Every finding a review gate produces must declare **`consequence: <what breaks, who observes it>`** —
a concrete failure (a broken behaviour, a lost invariant, a wrong result) **and** the party who
observes it (a user, an operator, a downstream component, CI). A restatement of the finding, a severity
word, or a bare "it breaks" is **not** a consequence.

**A finding without an adequate consequence is advisory: non-blocking, not counted toward the gate, and
not filed as a GitHub issue.** This governs findings raised inside a review gate. `AGENTS.md`'s
auto-file rule is written unconditionally, is **not** amended by this skill, and nothing in the harness
makes a skill outrank the always-loaded root instructions — the two texts are **not mechanically
reconciled**. This rule states the *intended* behaviour for a finding raised inside a review gate: such a
finding is **not** to be filed. Nothing in the harness *forces* that — an agent that ignores this rule
may still file one under `AGENTS.md:27`, which is the residual below. The residual — `AGENTS.md` still files a
consequence-less finding on *incidental discovery while working*, i.e. outside any gate — is **known and
unfixed**: #906, which would have scoped it, was closed **NOT_PLANNED** on 2026-09-15 (as was #903), so
nothing tracks it. Closing it needs a clause in `AGENTS.md` and `templates/AGENTS.base.md`; that is a
deliberate scope decision, not an oversight. For a gate's
exit conditions the clean predicate is that gate's own **full** clean token, never a count and never a
substring (e.g. `NO ISSUES FOUND — DEGRADED` is not clean).

**Conformance floor.** If a cycle yields ≥1 finding and **none** carries an adequate `consequence:`, that
is malformed reviewer output, not a clean cycle: record `⚠️ reviewer returned N consequence-less
findings`, re-dispatch once, and then exit **non-clean**. **Where the gate's own bound is already spent,
record the marker and exit non-clean without the extra dispatch** — the floor never widens a bound, and
`AGENTS.md` §Hard Cap counts every dispatch as a round. Voided findings are still written to the cycle
log, so convergence and stall detection read them and cannot read a shrunken set as convergence. Findings
from reviewers that are *advisory by construction* (`duplication-architecture`; `improvement-opportunities`
P1/P2) are recorded, never counted, and **do not trigger the floor**.

The token is exactly `consequence:` — lowercase, one spelling.

**This floor is not the "unverdict findings" disposition.** Several gates carry an advisory row reading
"`ISSUES` with **no** verdict → record `⚠️ reviewer returned unverdict findings` and proceed". That row
governs reviewers that are advisory *by construction* and is unaffected. The two triggers are distinct:
an **unverdict** result (the reviewer returned no parseable verdict) proceeds; a **consequence-less
blocking finding** (a parsed finding with no adequate consequence) is voided and cannot exit clean. A
gate carrying both rows must state which one applies.

---

## Consuming These Tables

Consuming skills **cite** `proportional-gates` §Review Cycles by name and never copy its cells — a copy is a second source of truth, and it is not the table the parity test parses, so it drifts silently.

The **judgment principle** and the domain tables (e.g. workspace isolation, pre-flight verification, dependency verification, research depth) may be restated or inlined in a consuming skill's own words — "replace rigid rules with judgment-based gating", and the Reviewer-Validates-Judgment pattern above. Reviewer counts and cycle caps may not.

---

## When NOT to Apply Proportionality

Some gates should remain absolute — they catch catastrophic failures that judgment cannot reliably predict:

| Gate | Why Absolute |
|------|-------------|
| pgTAP on migrations | Data loss from bad migrations is irreversible. Always run. |
| P0 human gates | Data loss, security, legal/compliance, cost >$10/mo. Always pause. |
| Commit to main/master | Never. Always use a branch. |
| Force push to main | Never. |

Proportionality applies to **verification depth**, not to **safety invariants**.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.


## Review Gate Routing by Level

For review gates that dispatch sub-agent reviewers, route by the issue's Level field:

| Level | Dispatch | Rationale |
|-------|----------|-----------|
| **Epic** | Sub-agent reviewer (fresh context) | Full adversarial check needed; scope justifies dispatch cost |

**Fallback:** If Level has no row above (missing or unrecognized), default to sub-agent review (safe default = full review, never skip).

**Skills affected:** `plan-review`, `code-review`, `test-review`, and any skill that dispatches reviewer sub-agents.

**Enforcement:** The skill-enforcer extension already requires the relevant skill to be read before the operation. This routing table is an agent instruction — the agent reads this skill and applies the rule.
